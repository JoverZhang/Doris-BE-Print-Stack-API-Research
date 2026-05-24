// Tiny test DSO loaded by the dlopen workload. The exported symbols are
// intentionally simple — what matters is that opening and closing the DSO
// forces the dynamic loader to take the loader lock, which is the deadlock
// surface we want to exercise against the kill60 implementation.

#include <atomic>

extern "C" {

static std::atomic<int> g_init_calls{0};
static std::atomic<int> g_fini_calls{0};

__attribute__((constructor)) void doris_bench_dso_ctor() {
  g_init_calls.fetch_add(1, std::memory_order_relaxed);
}

__attribute__((destructor)) void doris_bench_dso_dtor() {
  g_fini_calls.fetch_add(1, std::memory_order_relaxed);
}

int doris_bench_dso_init_count() { return g_init_calls.load(std::memory_order_relaxed); }
int doris_bench_dso_fini_count() { return g_fini_calls.load(std::memory_order_relaxed); }

}  // extern "C"
