#pragma once

#include "doris_stacktrace.h"

#include <signal.h>
#include <sys/types.h>
#include <ucontext.h>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace doris::stacktrace::internal {

enum class FrameKind : int { kKill = 1, kSnapshot = 2 };

constexpr int kMaxSnapshotFrames = 64;

struct SnapshotFrame {
  FrameKind                 kind;
  pid_t                     tid;
  char                      name[16];
  std::atomic<int>          status;
  std::uint64_t             t_send_ns;
  std::uint64_t             t_handler_enter_ns;
  std::uint64_t             t_handler_exit_ns;
  ucontext_t                ctx;
  std::uintptr_t            copy_start;
  std::size_t               copy_len;
  alignas(16) std::uint8_t  buffer[kStackCopyBytes];
};

struct UnwindResult {
  std::vector<std::uintptr_t> pcs;
  bool                        truncated;
};

// Built/updated from dl_iterate_phdr. Cheap to call on the entry thread but
// blocks behind any concurrent dlopen, so must not run inside a signal handler.
void rebuild_dso_cache();

// Walks frames from frame->ctx using custom libunwind accessors backed by
// frame->buffer for stack reads and DSO PT_LOAD ranges for code reads.
UnwindResult remote_unwind(SnapshotFrame *frame, int max_frames);

// Async-signal-safe utilities. byte_copy is hand-rolled because memcpy is not
// on the POSIX async-signal-safe list; clock_gettime_safe wraps
// clock_gettime(CLOCK_MONOTONIC) which is on the list.
void          byte_copy(void *dst, const void *src, std::size_t n);
std::uint64_t clock_gettime_safe();

std::vector<pid_t> enumerate_tasks_except_self();

void resolve_with_dladdr(std::uintptr_t pc, Frame *out);

// One-shot installer for the shared SIGRTMIN+4 handler that dispatches to the
// per-impl handler based on the FrameKind tag at the start of the sival_ptr
// payload. Returns 0 on success, errno on failure.
int ensure_capture_handler_installed();

// Wraps rt_tgsigqueueinfo with sival_ptr=frame. Returns 0 on success, -1 on
// failure with errno set.
int send_capture(pid_t tid, void *frame);

// Per-impl handlers, defined in kill60.cpp / snapshot.cpp.
void kill60_handler  (siginfo_t *si, void *uctx);
void snapshot_handler(siginfo_t *si, void *uctx);

}  // namespace doris::stacktrace::internal
