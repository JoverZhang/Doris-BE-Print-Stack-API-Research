#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#define UNW_LOCAL_ONLY

#include <dirent.h>
#include <fcntl.h>
#include <libunwind.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <thread>
#include <vector>

static constexpr int kTriggerSignal = 60;
static constexpr int kMultipurposeSignal = SIGURG;
static constexpr int kMaxFrames = 64;

static int request_pipe[2] = {-1, -1};
static std::atomic<bool> stop_requested{false};

struct Processor {
  int fd = -1;
  char filename[128] = {};
  char line[8192] = {};
  int line_len = 0;

  Processor()
  {
    time_t now = time(nullptr);
    snprintf(filename, sizeof(filename), "stack.%d.%ld", getpid(), static_cast<long>(now));
    fd = open(filename, O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC, 0600);
  }

  ~Processor()
  {
    if (fd >= 0) {
      close(fd);
    }
  }

  void start()
  {
    if (fd < 0) return;
    int maps_fd = open("/proc/self/maps", O_RDONLY | O_CLOEXEC);
    if (maps_fd < 0) return;
    char buf[4096];
    ssize_t n = 0;
    while ((n = read(maps_fd, buf, sizeof(buf))) > 0) {
      write(fd, buf, static_cast<size_t>(n));
    }
    close(maps_fd);
  }

  int prepare()
  {
    char tname[16] = {};
    prctl(PR_GET_NAME, tname);
    line_len = snprintf(line, sizeof(line), "tid: %ld, tname: %s, lbt: ",
        static_cast<long>(syscall(SYS_gettid)), tname);

    unw_context_t context;
    unw_cursor_t cursor;
    if (unw_getcontext(&context) < 0 || unw_init_local(&cursor, &context) < 0) {
      line_len += snprintf(line + line_len, sizeof(line) - static_cast<size_t>(line_len), "unwind_failed");
    } else {
      for (int i = 0; i < kMaxFrames && line_len < static_cast<int>(sizeof(line)) - 32; ++i) {
        unw_word_t ip = 0;
        if (unw_get_reg(&cursor, UNW_REG_IP, &ip) < 0) break;
        line_len += snprintf(line + line_len, sizeof(line) - static_cast<size_t>(line_len),
            "%s0x%lx", i == 0 ? "" : " ", static_cast<unsigned long>(ip));
        int step = unw_step(&cursor);
        if (step <= 0) break;
      }
    }
    if (line_len < static_cast<int>(sizeof(line)) - 1) {
      line[line_len++] = '\n';
    }
    return 0;
  }

  int process()
  {
    if (fd >= 0 && line_len > 0) {
      write(fd, line, static_cast<size_t>(line_len));
    }
    return 0;
  }
};

struct HandlerCtx {
  int fd[2] = {-1, -1};
  int fd2[2] = {-1, -1};
  Processor *processor = nullptr;
  std::atomic<int64_t> req_id{0};
};

struct Request {
  int exclude_tid = -1;
  int ack_fd[2] = {-1, -1};
};

static HandlerCtx handler_ctx;

static int wait_readable(int fd, int timeout_ms)
{
  pollfd pfd{fd, POLLIN, 0};
  int rc = poll(&pfd, 1, timeout_ms);
  return rc > 0 ? 0 : -1;
}

static void directed_signal_handler(int sig, siginfo_t *si, void *)
{
  if (sig != kMultipurposeSignal) return;
  int64_t req_id = reinterpret_cast<int64_t>(si->si_value.sival_ptr);
  if (handler_ctx.req_id.load(std::memory_order_acquire) != req_id || handler_ctx.processor == nullptr) return;

  int ack = handler_ctx.processor->prepare();
  write(handler_ctx.fd[1], &ack, sizeof(ack));

  if (wait_readable(handler_ctx.fd2[0], 1000) == 0) {
    read(handler_ctx.fd2[0], &ack, sizeof(ack));
  }
  write(handler_ctx.fd[1], &ack, sizeof(ack));
}

static void install_signal_handlers()
{
  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_flags = SA_SIGINFO | SA_RESTART | SA_NODEFER | SA_ONSTACK;
  sa.sa_sigaction = directed_signal_handler;
  sigemptyset(&sa.sa_mask);
  if (sigaction(kMultipurposeSignal, &sa, nullptr) != 0) {
    perror("sigaction");
    exit(1);
  }
}

static void iter_tasks(void (*cb)(int, int, Request *, Processor *), int exclude_tid,
    Request *req, Processor *processor)
{
  DIR *dir = opendir("/proc/self/task");
  if (dir == nullptr) return;
  int tgid = getpid();
  int self_tid = static_cast<int>(syscall(SYS_gettid));
  while (dirent *entry = readdir(dir)) {
    if (entry->d_name[0] == '.') continue;
    int tid = atoi(entry->d_name);
    if (tid != self_tid && tid != exclude_tid) {
      cb(tgid, tid, req, processor);
    }
  }
  closedir(dir);
}

static void task_process(int tgid, int tid, Request *req, Processor *processor)
{
  pipe2(handler_ctx.fd, O_CLOEXEC);
  pipe2(handler_ctx.fd2, O_CLOEXEC);
  handler_ctx.processor = processor;
  static std::atomic<int64_t> seq{0};
  int64_t req_id = seq.fetch_add(1) + 1;
  handler_ctx.req_id.store(req_id, std::memory_order_release);

  siginfo_t si;
  memset(&si, 0, sizeof(si));
  si.si_code = SI_QUEUE;
  si.si_value.sival_ptr = reinterpret_cast<void *>(req_id);
  int rc = syscall(SYS_rt_tgsigqueueinfo, tgid, tid, kMultipurposeSignal, &si);
  if (rc == 0 && wait_readable(handler_ctx.fd[0], 500) == 0) {
    int ack = 0;
    read(handler_ctx.fd[0], &ack, sizeof(ack));
    ack = processor->process();
    write(handler_ctx.fd2[1], &ack, sizeof(ack));
    wait_readable(handler_ctx.fd[0], 500);
    read(handler_ctx.fd[0], &ack, sizeof(ack));
  }

  handler_ctx.req_id.store(0, std::memory_order_release);
  handler_ctx.processor = nullptr;
  close(handler_ctx.fd[0]);
  close(handler_ctx.fd[1]);
  close(handler_ctx.fd2[0]);
  close(handler_ctx.fd2[1]);
  handler_ctx.fd[0] = handler_ctx.fd[1] = handler_ctx.fd2[0] = handler_ctx.fd2[1] = -1;
  (void)req;
}

static void signal_worker()
{
  prctl(PR_SET_NAME, "SignalWorker");
  while (!stop_requested.load()) {
    if (wait_readable(request_pipe[0], 100) != 0) continue;
    Request *req = nullptr;
    ssize_t n = read(request_pipe[0], &req, sizeof(req));
    if (n != sizeof(req) || req == nullptr) continue;
    Processor processor;
    processor.start();
    iter_tasks(task_process, req->exclude_tid, req, &processor);
    int ack = 0;
    write(req->ack_fd[1], &ack, sizeof(ack));
  }
}

static int send_request_and_wait(int exclude_tid)
{
  Request req;
  req.exclude_tid = exclude_tid;
  if (pipe2(req.ack_fd, O_CLOEXEC) != 0) return -1;
  Request *ptr = &req;
  write(request_pipe[1], &ptr, sizeof(ptr));
  int ack = -1;
  if (wait_readable(req.ack_fd[0], 5000) == 0) {
    read(req.ack_fd[0], &ack, sizeof(ack));
  }
  close(req.ack_fd[0]);
  close(req.ack_fd[1]);
  return ack;
}

static void signal_handle_thread()
{
  prctl(PR_SET_NAME, "SignalHandle");
  sigset_t waitset;
  sigemptyset(&waitset);
  sigaddset(&waitset, kTriggerSignal);
  timespec timeout{0, 100 * 1000 * 1000};
  while (!stop_requested.load()) {
    int signum = sigtimedwait(&waitset, nullptr, &timeout);
    if (signum == kTriggerSignal) {
      send_request_and_wait(static_cast<int>(syscall(SYS_gettid)));
    }
  }
}

static void worker_thread(int id)
{
  char name[16];
  snprintf(name, sizeof(name), "worker-%d", id);
  prctl(PR_SET_NAME, name);
  volatile uint64_t x = static_cast<uint64_t>(id + 1);
  while (!stop_requested.load()) {
    x = x * 1103515245 + 12345;
    if ((x & 0xfffff) == 0) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
  }
}

int main()
{
  sigset_t blocked;
  sigemptyset(&blocked);
  sigaddset(&blocked, kTriggerSignal);
  pthread_sigmask(SIG_BLOCK, &blocked, nullptr);

  install_signal_handlers();
  if (pipe2(request_pipe, O_CLOEXEC) != 0) {
    perror("pipe2");
    return 1;
  }

  printf("pid=%d\n", getpid());
  fflush(stdout);

  std::thread sig_worker(signal_worker);
  std::thread sig_handle(signal_handle_thread);
  std::vector<std::thread> workers;
  for (int i = 0; i < 4; ++i) {
    workers.emplace_back(worker_thread, i);
  }

  FILE *pid_file = fopen("minimal.pid", "w");
  if (pid_file != nullptr) {
    fprintf(pid_file, "%d\n", getpid());
    fclose(pid_file);
  }

  for (int i = 0; i < 50 && !stop_requested.load(); ++i) {
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
  }
  stop_requested.store(true);

  for (auto &worker : workers) {
    worker.join();
  }
  sig_handle.join();
  sig_worker.join();
  close(request_pipe[0]);
  close(request_pipe[1]);
  return 0;
}
