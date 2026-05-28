#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "doris_stacktrace_internal.h"

#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/ucontext.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <mutex>
#include <new>
#include <thread>
#include <vector>

namespace doris::stacktrace {

namespace {
thread_local std::uintptr_t tls_stack_high = 0;

// See kill60.cpp for the lifetime rationale. The graveyard prevents UAF when
// a late signal handler fires on a frame the entry thread has already given
// up on.
std::mutex                          g_snap_graveyard_mu;
std::vector<internal::SnapshotFrame *> g_snap_graveyard;

void destroy_snapshot_frame(internal::SnapshotFrame *f) {
  f->~SnapshotFrame();
  ::operator delete(f, std::align_val_t{16});
}

void sweep_snap_graveyard() {
  std::lock_guard<std::mutex> g(g_snap_graveyard_mu);
  auto it = g_snap_graveyard.begin();
  while (it != g_snap_graveyard.end()) {
    if ((*it)->status.load(std::memory_order_acquire) != 0) {
      destroy_snapshot_frame(*it);
      it = g_snap_graveyard.erase(it);
    } else {
      ++it;
    }
  }
}

void retire_snapshot_frame(internal::SnapshotFrame *f) {
  if (f->status.load(std::memory_order_acquire) != 0) {
    destroy_snapshot_frame(f);
    return;
  }
  std::lock_guard<std::mutex> g(g_snap_graveyard_mu);
  g_snap_graveyard.push_back(f);
}

}  // namespace

void snapshot_register_self() {
  pthread_attr_t attr;
  if (pthread_getattr_np(pthread_self(), &attr) != 0) return;
  void  *base = nullptr;
  size_t size = 0;
  if (pthread_attr_getstack(&attr, &base, &size) == 0) {
    tls_stack_high = reinterpret_cast<std::uintptr_t>(base) + size;
  }
  pthread_attr_destroy(&attr);
}

namespace internal {

void snapshot_handler(siginfo_t *si, void *uctx) {
  SnapshotFrame *f = static_cast<SnapshotFrame *>(si->si_value.sival_ptr);
  f->t_handler_enter_ns = clock_gettime_safe();

  if (tls_stack_high == 0) {
    f->status.store(-2, std::memory_order_release);
    return;
  }

  prctl(PR_GET_NAME, f->name);

  ucontext_t *uc = static_cast<ucontext_t *>(uctx);
  f->ctx = *uc;

  std::uintptr_t rsp = static_cast<std::uintptr_t>(uc->uc_mcontext.gregs[REG_RSP]);
  f->copy_start = rsp;
  std::size_t want = (tls_stack_high > rsp) ? (tls_stack_high - rsp) : 0;
  f->copy_len  = want < kStackCopyBytes ? want : kStackCopyBytes;

  if (f->copy_len > 0) {
    byte_copy(f->buffer, reinterpret_cast<const void *>(rsp), f->copy_len);
  }

  f->t_handler_exit_ns = clock_gettime_safe();
  f->status.store(1, std::memory_order_release);
}

}  // namespace internal

DumpResult dump_all_threads_snapshot(std::chrono::milliseconds per_thread_timeout) {
  using clock = std::chrono::steady_clock;
  auto t0 = clock::now();

  internal::ensure_capture_handler_installed();
  sweep_snap_graveyard();
  internal::rebuild_dso_cache();
  auto tids = internal::enumerate_tasks_except_self();

  // SnapshotFrame embeds a kStackCopyBytes buffer; allocate one per target with
  // 16-byte alignment to keep ucontext register loads/stores happy.
  std::vector<internal::SnapshotFrame *> frames;
  frames.reserve(tids.size());
  for (pid_t tid : tids) {
    void *mem = ::operator new(sizeof(internal::SnapshotFrame), std::align_val_t{16});
    auto *f = new (mem) internal::SnapshotFrame();
    f->kind = internal::FrameKind::kSnapshot;
    f->tid  = tid;
    f->name[0] = '\0';
    f->status.store(0, std::memory_order_relaxed);
    f->copy_start = 0;
    f->copy_len   = 0;
    frames.push_back(f);
  }

  // Fire all signals first (parallel dispatch).
  for (auto *f : frames) {
    f->t_send_ns = internal::clock_gettime_safe();
    if (internal::send_capture(f->tid, f) != 0) {
      f->status.store(-1, std::memory_order_release);
    }
  }

  // Collect with per-thread deadlines.
  auto timeout_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(per_thread_timeout).count();
  for (auto *f : frames) {
    if (f->status.load(std::memory_order_acquire) != 0) continue;
    auto deadline = f->t_send_ns + static_cast<std::uint64_t>(timeout_ns);
    while (f->status.load(std::memory_order_acquire) == 0) {
      if (internal::clock_gettime_safe() >= deadline) break;
      std::this_thread::sleep_for(std::chrono::microseconds(50));
    }
  }

  DumpResult result;
  result.threads.reserve(frames.size());
  for (auto *f : frames) {
    ThreadDump td;
    td.tid          = f->tid;
    td.name         = f->name[0] ? std::string(f->name) : std::string();
    td.truncated    = false;
    td.dispatch_ns  = std::chrono::nanoseconds(0);
    td.handler_ns   = std::chrono::nanoseconds(0);

    int st = f->status.load(std::memory_order_acquire);
    if (st == 1) {
      td.status      = DumpStatus::OK;
      td.dispatch_ns = std::chrono::nanoseconds(f->t_handler_enter_ns > f->t_send_ns
                          ? f->t_handler_enter_ns - f->t_send_ns : 0);
      td.handler_ns  = std::chrono::nanoseconds(f->t_handler_exit_ns > f->t_handler_enter_ns
                          ? f->t_handler_exit_ns - f->t_handler_enter_ns : 0);
      auto ur = internal::remote_unwind(f, internal::kMaxSnapshotFrames);
      td.truncated = ur.truncated;
      td.frames.reserve(ur.pcs.size());
      for (auto pc : ur.pcs) {
        Frame fr;
        internal::resolve_with_dladdr(pc, &fr);
        td.frames.push_back(std::move(fr));
      }
    } else if (st == -2) {
      td.status = DumpStatus::UNREGISTERED;
    } else if (st == 0) {
      td.status = DumpStatus::TIMED_OUT;
    } else {
      td.status = DumpStatus::ERROR;
    }
    result.threads.push_back(std::move(td));
  }

  // Retire frames: completed now, pending to graveyard so a late signal
  // handler cannot write into freed memory.
  for (auto *f : frames) retire_snapshot_frame(f);

  result.elapsed_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(clock::now() - t0);
  return result;
}

}  // namespace doris::stacktrace
