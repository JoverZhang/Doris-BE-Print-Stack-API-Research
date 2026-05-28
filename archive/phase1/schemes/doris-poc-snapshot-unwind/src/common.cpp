#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "doris_stacktrace_internal.h"

#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

namespace doris::stacktrace::internal {

void byte_copy(void *dst, const void *src, std::size_t n) {
  auto       *d = static_cast<unsigned char       *>(dst);
  const auto *s = static_cast<const unsigned char *>(src);
  while (n--) *d++ = *s++;
}

std::uint64_t clock_gettime_safe() {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return static_cast<std::uint64_t>(ts.tv_sec) * 1000000000ull
       + static_cast<std::uint64_t>(ts.tv_nsec);
}

std::vector<pid_t> enumerate_tasks_except_self() {
  std::vector<pid_t> tids;
  pid_t self = static_cast<pid_t>(syscall(SYS_gettid));
  DIR *d = opendir("/proc/self/task");
  if (!d) return tids;
  for (dirent *e; (e = readdir(d)) != nullptr; ) {
    if (e->d_name[0] == '.') continue;
    pid_t tid = static_cast<pid_t>(atoi(e->d_name));
    if (tid > 0 && tid != self) tids.push_back(tid);
  }
  closedir(d);
  return tids;
}

void resolve_with_dladdr(std::uintptr_t pc, Frame *out) {
  out->pc = pc;
  out->offset = 0;
  Dl_info info;
  if (dladdr(reinterpret_cast<void *>(pc), &info)) {
    if (info.dli_sname) out->sym = info.dli_sname;
    if (info.dli_saddr) {
      out->offset = pc - reinterpret_cast<std::uintptr_t>(info.dli_saddr);
    }
    if (info.dli_fname) {
      const char *slash = strrchr(info.dli_fname, '/');
      out->dso = slash ? slash + 1 : info.dli_fname;
    }
  }
}

static void shared_capture_handler(int sig, siginfo_t *si, void *uctx) {
  (void)sig;
  if (!si || !si->si_value.sival_ptr) return;
  FrameKind kind = *static_cast<FrameKind *>(si->si_value.sival_ptr);
  if (kind == FrameKind::kKill) {
    kill60_handler(si, uctx);
  } else if (kind == FrameKind::kSnapshot) {
    snapshot_handler(si, uctx);
  }
}

static pthread_once_t g_handler_once          = PTHREAD_ONCE_INIT;
static int            g_handler_install_errno = 0;

static void install_capture_handler_once() {
  struct sigaction sa{};
  sa.sa_flags     = SA_SIGINFO | SA_NODEFER | SA_ONSTACK | SA_RESTART;
  sa.sa_sigaction = shared_capture_handler;
  sigemptyset(&sa.sa_mask);
  if (sigaction(SIGRTMIN + 4, &sa, nullptr) != 0) {
    g_handler_install_errno = errno;
  }
}

int ensure_capture_handler_installed() {
  pthread_once(&g_handler_once, install_capture_handler_once);
  return g_handler_install_errno;
}

int send_capture(pid_t tid, void *frame) {
  siginfo_t si{};
  si.si_code            = SI_QUEUE;
  si.si_pid             = getpid();
  si.si_uid             = getuid();
  si.si_value.sival_ptr = frame;
  long rc = syscall(SYS_rt_tgsigqueueinfo, getpid(), tid, SIGRTMIN + 4, &si);
  return rc == 0 ? 0 : -1;
}

}  // namespace doris::stacktrace::internal
