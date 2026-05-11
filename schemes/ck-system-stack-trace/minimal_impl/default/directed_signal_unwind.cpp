#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <libunwind.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <algorithm>
#include <iostream>
#include <string>
#include <vector>

namespace {

constexpr int kMaxFrames = 16;
constexpr int kTimeoutMs = 100;

struct Record {
  int sequence;
  pid_t tid;
  int depth;
  uintptr_t pcs[kMaxFrames];
};

int g_pipe[2] = {-1, -1};

pid_t gettid_syscall() {
  return static_cast<pid_t>(syscall(SYS_gettid));
}

int rt_tgsigqueueinfo(pid_t tgid, pid_t tid, int sig, siginfo_t* info) {
  return static_cast<int>(syscall(SYS_rt_tgsigqueueinfo, tgid, tid, sig, info));
}

void handler(int, siginfo_t* info, void*) {
  Record record{};
  record.sequence = info ? info->si_value.sival_int : -1;
  record.tid = gettid_syscall();

  void* frames[kMaxFrames]{};
  int depth = unw_backtrace(frames, kMaxFrames);
  record.depth = std::max(0, depth);
  for (int i = 0; i < record.depth && i < kMaxFrames; ++i) {
    record.pcs[i] = reinterpret_cast<uintptr_t>(frames[i]);
  }

  ssize_t ignored = write(g_pipe[1], &record, sizeof(record));
  (void)ignored;
}

std::vector<pid_t> list_threads() {
  std::vector<pid_t> tids;
  DIR* dir = opendir("/proc/self/task");
  if (!dir) {
    perror("opendir");
    return tids;
  }
  while (dirent* ent = readdir(dir)) {
    if (ent->d_name[0] == '.') {
      continue;
    }
    tids.push_back(static_cast<pid_t>(std::stoi(ent->d_name)));
  }
  closedir(dir);
  std::sort(tids.begin(), tids.end());
  return tids;
}

}  // namespace

int main() {
  const int signal_number = SIGRTMIN;
  if (pipe2(g_pipe, O_CLOEXEC) != 0) {
    perror("pipe2");
    return 1;
  }

  struct sigaction action {};
  action.sa_sigaction = handler;
  action.sa_flags = SA_SIGINFO;
  sigemptyset(&action.sa_mask);
  sigaddset(&action.sa_mask, signal_number);
  if (sigaction(signal_number, &action, nullptr) != 0) {
    perror("sigaction");
    return 1;
  }

  pid_t pid = getpid();
  int sequence = 1;
  int ok = 0;
  int timeout = 0;

  for (pid_t tid : list_threads()) {
    siginfo_t info {};
    info.si_code = SI_QUEUE;
    info.si_pid = pid;
    info.si_value.sival_int = sequence;

    if (rt_tgsigqueueinfo(pid, tid, signal_number, &info) != 0) {
      std::cout << "thread tid=" << tid << " send_error=" << strerror(errno) << "\n";
      ++sequence;
      continue;
    }

    pollfd pfd{g_pipe[0], POLLIN, 0};
    if (poll(&pfd, 1, kTimeoutMs) <= 0) {
      std::cout << "thread tid=" << tid << " timeout=1\n";
      ++timeout;
      ++sequence;
      continue;
    }

    Record record {};
    ssize_t n = read(g_pipe[0], &record, sizeof(record));
    if (n != sizeof(record) || record.sequence != sequence) {
      std::cout << "thread tid=" << tid << " bad_record=1\n";
      ++sequence;
      continue;
    }

    std::cout << "thread tid=" << record.tid << " depth=" << record.depth << " pcs=[";
    for (int i = 0; i < record.depth; ++i) {
      if (i) {
        std::cout << ",";
      }
      std::cout << "0x" << std::hex << record.pcs[i] << std::dec;
    }
    std::cout << "]\n";
    ++ok;
    ++sequence;
  }

  std::cout << "summary ok=" << ok << " timeout=" << timeout << "\n";
  return ok > 0 ? 0 : 2;
}
