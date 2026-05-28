// Correctness check requested by PLAN.md §12 step 3.
//
// Drive a worker into a known deep call chain, snap its ucontext + stack into
// a SnapshotFrame from a private signal handler that ALSO records a reference
// PC list via unw_init_local2(UNW_INIT_SIGNAL_FRAME). Then run remote_unwind()
// on the same frame from the main thread and require the resulting PC prefix
// to match the reference exactly until either side runs out (the remote side
// terminates when libunwind needs stack memory outside the snapshot window).

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "doris_stacktrace.h"
#include "doris_stacktrace_internal.h"

#include <libunwind.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <new>
#include <thread>

namespace dst = doris::stacktrace;
namespace dsi = doris::stacktrace::internal;

namespace {

int cmp_signal() { return SIGRTMIN + 5; }

struct CombinedFrame {
  dsi::SnapshotFrame   snap;
  std::uintptr_t       ref_pcs[64];
  int                  ref_n;
  std::atomic<int>     done;
  std::atomic<bool>    worker_ready;  // released after snap.tid + stack_high are populated
  std::uintptr_t       stack_high;
};

void combined_handler(int, siginfo_t *si, void *uctx) {
  auto *cf = static_cast<CombinedFrame *>(si->si_value.sival_ptr);
  ucontext_t *uc = static_cast<ucontext_t *>(uctx);

  // Reference PC list via local libunwind.
  unw_cursor_t c;
  cf->ref_n = 0;
  if (unw_init_local2(&c, reinterpret_cast<unw_context_t *>(uc),
                      UNW_INIT_SIGNAL_FRAME) == 0) {
    do {
      unw_word_t ip = 0;
      if (unw_get_reg(&c, UNW_REG_IP, &ip) < 0) break;
      cf->ref_pcs[cf->ref_n++] = static_cast<std::uintptr_t>(ip);
    } while (cf->ref_n < 64 && unw_step(&c) > 0);
  }

  // Snapshot copy (mirrors src/snapshot.cpp's handler).
  cf->snap.ctx = *uc;
  auto rsp = static_cast<std::uintptr_t>(uc->uc_mcontext.gregs[REG_RSP]);
  cf->snap.copy_start = rsp;
  std::size_t want = (cf->stack_high > rsp) ? (cf->stack_high - rsp) : 0;
  cf->snap.copy_len  = want < dst::kStackCopyBytes ? want : dst::kStackCopyBytes;
  if (cf->snap.copy_len > 0) {
    auto       *d = cf->snap.buffer;
    const auto *s = reinterpret_cast<const std::uint8_t *>(rsp);
    for (std::size_t i = 0; i < cf->snap.copy_len; ++i) d[i] = s[i];
  }
  cf->snap.status.store(1, std::memory_order_release);

  cf->done.store(1, std::memory_order_release);
}

// noinline alone does not block sibling-call optimization at -O2, so each
// wrapper takes a sink that we read after the call to make tail elimination
// impossible. Combined with the TU-level -fno-optimize-sibling-calls flag
// applied in CMake, this keeps mid_a / mid_b on the stack and gives the
// remote unwind a real multi-frame chain to walk.
volatile int g_sibling_call_sink = 0;

void __attribute__((noinline)) leaf_spin(CombinedFrame *cf) {
  // Release ONLY after the intended call chain (leaf_spin <- mid_b <- mid_a
  // <- worker) is established. Publishing earlier (e.g. from worker())
  // exposes a race where the worker is preempted between the release and
  // mid_a; under load the signal can arrive before the chain is on stack.
  cf->worker_ready.store(true, std::memory_order_release);
  while (cf->done.load(std::memory_order_acquire) == 0) {
    asm volatile("" ::: "memory");
  }
}

void __attribute__((noinline)) mid_b(CombinedFrame *cf) {
  leaf_spin(cf);
  g_sibling_call_sink += 1;
}

void __attribute__((noinline)) mid_a(CombinedFrame *cf) {
  mid_b(cf);
  g_sibling_call_sink += 1;
}

void worker(CombinedFrame *cf) {
  // Capture stack high here in the worker context. Non-atomic stores; main
  // observes them transitively via the release in leaf_spin (program order
  // here happens-before the release after the chained calls).
  pthread_attr_t attr;
  pthread_getattr_np(pthread_self(), &attr);
  void  *base = nullptr;
  size_t sz   = 0;
  pthread_attr_getstack(&attr, &base, &sz);
  pthread_attr_destroy(&attr);
  cf->stack_high = reinterpret_cast<std::uintptr_t>(base) + sz;
  cf->snap.tid   = static_cast<pid_t>(syscall(SYS_gettid));
  mid_a(cf);
  g_sibling_call_sink += 1;
}

}  // namespace

int main() {
  struct sigaction sa{};
  sa.sa_flags     = SA_SIGINFO | SA_NODEFER | SA_ONSTACK | SA_RESTART;
  sa.sa_sigaction = combined_handler;
  sigemptyset(&sa.sa_mask);
  if (sigaction(cmp_signal(), &sa, nullptr) != 0) {
    perror("sigaction");
    return 2;
  }

  dsi::rebuild_dso_cache();

  void *mem = ::operator new(sizeof(CombinedFrame), std::align_val_t{16});
  auto *cf  = new (mem) CombinedFrame();
  cf->snap.kind = dsi::FrameKind::kSnapshot;
  cf->snap.status.store(0);
  cf->snap.copy_start = 0;
  cf->snap.copy_len   = 0;
  cf->ref_n           = 0;
  cf->done.store(0);
  cf->worker_ready.store(false);

  std::thread t(worker, cf);
  // Acquire pairs with the release in leaf_spin — once observed, the worker
  // is in the spin loop with the full intended chain on the stack, and
  // stack_high / snap.tid (program-order-before that release) are visible.
  // No additional sleep needed.
  while (!cf->worker_ready.load(std::memory_order_acquire)) {
    std::this_thread::sleep_for(std::chrono::microseconds(100));
  }

  siginfo_t si{};
  si.si_code            = SI_QUEUE;
  si.si_value.sival_ptr = cf;
  if (syscall(SYS_rt_tgsigqueueinfo, getpid(), cf->snap.tid, cmp_signal(), &si) != 0) {
    perror("rt_tgsigqueueinfo");
    return 2;
  }

  // Wait for the handler to finish populating cf.
  while (cf->done.load(std::memory_order_acquire) == 0) {
    std::this_thread::sleep_for(std::chrono::microseconds(50));
  }
  t.join();

  auto ur = dsi::remote_unwind(&cf->snap, 64);

  std::printf("reference frames (%d):\n", cf->ref_n);
  for (int i = 0; i < cf->ref_n; ++i)
    std::printf("  ref[%2d] 0x%012lx\n", i, static_cast<unsigned long>(cf->ref_pcs[i]));
  std::printf("remote frames (%zu, truncated=%d):\n", ur.pcs.size(), static_cast<int>(ur.truncated));
  for (std::size_t i = 0; i < ur.pcs.size(); ++i)
    std::printf("  rem[%2zu] 0x%012lx\n", i, static_cast<unsigned long>(ur.pcs[i]));

  // Compare the PC sequences as a prefix match. The remote unwind is expected
  // to be a prefix of the reference (it terminates when libunwind tries to
  // read stack memory outside the copy window).
  int matched = 0;
  for (std::size_t i = 0; i < ur.pcs.size() && static_cast<int>(i) < cf->ref_n; ++i) {
    if (ur.pcs[i] != cf->ref_pcs[i]) break;
    ++matched;
  }
  bool prefix_ok = (matched == static_cast<int>(ur.pcs.size())) &&
                   (ur.pcs.size() <= static_cast<std::size_t>(cf->ref_n));
  // Require leaf_spin + mid_b + mid_a + worker — the chain we intentionally
  // built. If sibling-call optimization elided any of these, the count drops
  // below 4 and the test fails loudly.
  bool depth_ok  = matched >= 4;

  std::printf("match=%d reference=%d remote=%zu prefix_ok=%d depth_ok=%d  RESULT=%s\n",
              matched, cf->ref_n, ur.pcs.size(), prefix_ok, depth_ok,
              (prefix_ok && depth_ok) ? "PASS" : "FAIL");

  cf->~CombinedFrame();
  ::operator delete(mem, std::align_val_t{16});
  return (prefix_ok && depth_ok) ? 0 : 1;
}
