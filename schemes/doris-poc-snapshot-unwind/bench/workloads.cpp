#include "workloads.h"
#include "doris_stacktrace.h"

#include <dlfcn.h>
#include <stdio.h>
#include <sys/prctl.h>

#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <mutex>
#include <random>
#include <thread>
#include <vector>

namespace doris::stacktrace::bench {

namespace {

void __attribute__((noinline)) deep_layer_d(volatile std::uint64_t *x) { *x = (*x) * 6364136223846793005ull + 1442695040888963407ull; }
void __attribute__((noinline)) deep_layer_c(volatile std::uint64_t *x) { deep_layer_d(x); }
void __attribute__((noinline)) deep_layer_b(volatile std::uint64_t *x) { deep_layer_c(x); }
void __attribute__((noinline)) deep_layer_a(volatile std::uint64_t *x) { deep_layer_b(x); }

void idle_worker(WorkloadHandle *h, int id) {
  char name[16]; snprintf(name, sizeof(name), "idle-%d", id); prctl(PR_SET_NAME, name);
  snapshot_register_self();
  while (!h->stop.load(std::memory_order_relaxed)) {
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
}

void spin_worker(WorkloadHandle *h, int id) {
  char name[16]; snprintf(name, sizeof(name), "spin-%d", id); prctl(PR_SET_NAME, name);
  snapshot_register_self();
  volatile std::uint64_t x = static_cast<std::uint64_t>(id + 1);
  while (!h->stop.load(std::memory_order_relaxed)) {
    deep_layer_a(&x);
  }
}

void alloc_worker(WorkloadHandle *h, int id) {
  char name[16]; snprintf(name, sizeof(name), "alloc-%d", id); prctl(PR_SET_NAME, name);
  snapshot_register_self();
  std::mt19937_64 rng(0xc0ffee + id);
  std::uniform_int_distribution<int> sz(32, 4096);
  while (!h->stop.load(std::memory_order_relaxed)) {
    void *p = std::malloc(sz(rng));
    if (p) std::free(p);
  }
}

std::mutex g_lock_mutexes[4];

void lock_worker(WorkloadHandle *h, int id) {
  char name[16]; snprintf(name, sizeof(name), "lock-%d", id); prctl(PR_SET_NAME, name);
  snapshot_register_self();
  volatile std::uint64_t x = id;
  while (!h->stop.load(std::memory_order_relaxed)) {
    auto &m = g_lock_mutexes[id & 3];
    std::lock_guard<std::mutex> g(m);
    deep_layer_a(&x);
  }
}

void dlopen_worker(WorkloadHandle *h, int id) {
  char name[16]; snprintf(name, sizeof(name), "dlopen-%d", id); prctl(PR_SET_NAME, name);
  snapshot_register_self();
  const char *path = h->dso_path.c_str();
  while (!h->stop.load(std::memory_order_relaxed)) {
    void *handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL);
    if (handle) {
      std::this_thread::sleep_for(std::chrono::microseconds(50));
      dlclose(handle);
    } else {
      std::this_thread::sleep_for(std::chrono::microseconds(100));
    }
  }
}

}  // namespace

void start_workload(const std::string &name, int n, WorkloadHandle *out) {
  out->stop.store(false);
  out->threads.reserve(n);
  if (name == "idle") {
    for (int i = 0; i < n; ++i) out->threads.emplace_back(idle_worker, out, i);
  } else if (name == "spin") {
    for (int i = 0; i < n; ++i) out->threads.emplace_back(spin_worker, out, i);
  } else if (name == "alloc") {
    for (int i = 0; i < n; ++i) out->threads.emplace_back(alloc_worker, out, i);
  } else if (name == "lock") {
    for (int i = 0; i < n; ++i) out->threads.emplace_back(lock_worker, out, i);
  } else if (name == "dlopen") {
    // Most threads spin; last 1-2 do dlopen/dlclose. The dlopen pair is the
    // hazard surface that kill60 deadlocks against.
    int dl_count = (n >= 8) ? 2 : 1;
    for (int i = 0; i < n - dl_count; ++i) out->threads.emplace_back(spin_worker, out, i);
    for (int i = 0; i < dl_count; ++i) out->threads.emplace_back(dlopen_worker, out, n - dl_count + i);
  } else {
    fprintf(stderr, "unknown workload: %s\n", name.c_str());
    std::abort();
  }
}

void stop_and_join(WorkloadHandle *h) {
  h->stop.store(true);
  for (auto &t : h->threads) t.join();
  h->threads.clear();
}

}  // namespace doris::stacktrace::bench
