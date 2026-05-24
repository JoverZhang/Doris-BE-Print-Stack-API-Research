#pragma once

#ifndef DORIS_STACKTRACE_COPY_BYTES
#define DORIS_STACKTRACE_COPY_BYTES 8192
#endif

#include <signal.h>
#include <sys/types.h>

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace doris::stacktrace {

// SIGRTMIN is a glibc function call so the value cannot be constexpr.
inline int capture_signal() { return SIGRTMIN + 4; }

constexpr std::size_t kStackCopyBytes = DORIS_STACKTRACE_COPY_BYTES;

struct Frame {
  std::uintptr_t pc;
  std::string    sym;
  std::uintptr_t offset;
  std::string    dso;
};

enum class DumpStatus { OK, TIMED_OUT, UNREGISTERED, ERROR };

struct ThreadDump {
  pid_t                    tid;
  std::string              name;
  DumpStatus               status;
  std::vector<Frame>       frames;
  bool                     truncated;
  std::chrono::nanoseconds dispatch_ns;
  std::chrono::nanoseconds handler_ns;
};

struct DumpResult {
  std::vector<ThreadDump>  threads;
  std::chrono::nanoseconds elapsed_ns;
};

// Workers using the snapshot implementation must call this once at thread
// init. Caches the thread's stack high address; pthread_getattr_np is not
// async-signal-safe so this work cannot happen inside the signal handler.
void snapshot_register_self();

DumpResult dump_all_threads_kill60(
    std::chrono::milliseconds per_thread_timeout = std::chrono::milliseconds(100));

DumpResult dump_all_threads_snapshot(
    std::chrono::milliseconds per_thread_timeout = std::chrono::milliseconds(100));

}  // namespace doris::stacktrace
