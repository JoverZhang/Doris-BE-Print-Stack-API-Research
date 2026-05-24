#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#define UNW_LOCAL_ONLY

#include "doris_stacktrace_internal.h"

#include <libunwind.h>
#include <signal.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <ucontext.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <thread>
#include <vector>

namespace doris::stacktrace {

namespace {

constexpr int kMaxKillFrames = 64;

struct KillFrame {
  internal::FrameKind kind;
  pid_t               tid;
  char                name[16];
  std::atomic<int>    status;
  std::uint64_t       t_send_ns;
  std::uint64_t       t_handler_enter_ns;
  std::uint64_t       t_handler_exit_ns;
  int                 npc;
  std::uintptr_t      pcs[kMaxKillFrames];
};

}  // namespace

namespace internal {

void kill60_handler(siginfo_t *si, void *uctx) {
  KillFrame *f = static_cast<KillFrame *>(si->si_value.sival_ptr);
  f->t_handler_enter_ns = clock_gettime_safe();

  prctl(PR_GET_NAME, f->name);

  unw_cursor_t  cursor;
  unw_context_t *ctx = static_cast<unw_context_t *>(uctx);
  int n = 0;
  if (unw_init_local2(&cursor, ctx, UNW_INIT_SIGNAL_FRAME) == 0) {
    do {
      unw_word_t ip = 0;
      if (unw_get_reg(&cursor, UNW_REG_IP, &ip) < 0) break;
      f->pcs[n++] = static_cast<std::uintptr_t>(ip);
    } while (n < kMaxKillFrames && unw_step(&cursor) > 0);
  }
  f->npc = n;

  f->t_handler_exit_ns = clock_gettime_safe();
  f->status.store(1, std::memory_order_release);
}

}  // namespace internal

DumpResult dump_all_threads_kill60(std::chrono::milliseconds per_thread_timeout) {
  using clock = std::chrono::steady_clock;
  auto t0 = clock::now();

  internal::ensure_capture_handler_installed();
  auto tids = internal::enumerate_tasks_except_self();

  std::vector<KillFrame> frames(tids.size());
  for (std::size_t i = 0; i < tids.size(); ++i) {
    frames[i].kind   = internal::FrameKind::kKill;
    frames[i].tid    = tids[i];
    frames[i].name[0] = '\0';
    frames[i].status.store(0, std::memory_order_relaxed);
    frames[i].npc    = 0;
  }

  // Fire all signals first (parallel dispatch).
  for (auto &f : frames) {
    f.t_send_ns = internal::clock_gettime_safe();
    if (internal::send_capture(f.tid, &f) != 0) {
      f.status.store(-1, std::memory_order_release);
    }
  }

  // Collect with per-thread deadlines.
  auto timeout_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(per_thread_timeout).count();
  for (auto &f : frames) {
    if (f.status.load(std::memory_order_acquire) != 0) continue;
    auto deadline = f.t_send_ns + static_cast<std::uint64_t>(timeout_ns);
    while (f.status.load(std::memory_order_acquire) == 0) {
      if (internal::clock_gettime_safe() >= deadline) break;
      std::this_thread::sleep_for(std::chrono::microseconds(50));
    }
  }

  DumpResult result;
  result.threads.reserve(frames.size());
  for (auto &f : frames) {
    ThreadDump td;
    td.tid          = f.tid;
    td.name         = f.name[0] ? std::string(f.name) : std::string();
    td.truncated    = false;
    td.dispatch_ns  = std::chrono::nanoseconds(0);
    td.handler_ns   = std::chrono::nanoseconds(0);

    int st = f.status.load(std::memory_order_acquire);
    if (st == 1) {
      td.status      = DumpStatus::OK;
      td.dispatch_ns = std::chrono::nanoseconds(f.t_handler_enter_ns > f.t_send_ns
                          ? f.t_handler_enter_ns - f.t_send_ns : 0);
      td.handler_ns  = std::chrono::nanoseconds(f.t_handler_exit_ns > f.t_handler_enter_ns
                          ? f.t_handler_exit_ns - f.t_handler_enter_ns : 0);
      td.truncated   = (f.npc == kMaxKillFrames);
      td.frames.reserve(f.npc);
      for (int i = 0; i < f.npc; ++i) {
        Frame fr;
        internal::resolve_with_dladdr(f.pcs[i], &fr);
        td.frames.push_back(std::move(fr));
      }
    } else if (st == 0) {
      td.status = DumpStatus::TIMED_OUT;
    } else {
      td.status = DumpStatus::ERROR;
    }
    result.threads.push_back(std::move(td));
  }

  result.elapsed_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(clock::now() - t0);
  return result;
}

}  // namespace doris::stacktrace
