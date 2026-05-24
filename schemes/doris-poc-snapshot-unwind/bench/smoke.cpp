// Minimal end-to-end demo: spin up a few workers, dump with both
// implementations, and print the resulting traces with timing.

#include "doris_stacktrace.h"
#include "workloads.h"

#include <chrono>
#include <cstdio>
#include <thread>
#include <vector>

namespace dst = doris::stacktrace;

namespace {

const char *status_name(dst::DumpStatus s) {
  switch (s) {
    case dst::DumpStatus::OK:           return "OK";
    case dst::DumpStatus::TIMED_OUT:    return "TIMED_OUT";
    case dst::DumpStatus::UNREGISTERED: return "UNREGISTERED";
    case dst::DumpStatus::ERROR:        return "ERROR";
  }
  return "?";
}

void print(const char *label, const dst::DumpResult &r) {
  std::printf("=== %s  elapsed=%.3f ms  threads=%zu\n",
              label, r.elapsed_ns.count() / 1e6, r.threads.size());
  for (const auto &t : r.threads) {
    std::printf("  tid=%d name=%-15s status=%-12s frames=%2zu trunc=%d "
                "dispatch=%.2fus handler=%.2fus\n",
                t.tid, t.name.c_str(), status_name(t.status),
                t.frames.size(), static_cast<int>(t.truncated),
                t.dispatch_ns.count() / 1e3, t.handler_ns.count() / 1e3);
    for (std::size_t i = 0; i < t.frames.size() && i < 8; ++i) {
      const auto &f = t.frames[i];
      std::printf("    #%-2zu 0x%012lx %s+0x%lx (%s)\n",
                  i, f.pc, f.sym.empty() ? "?" : f.sym.c_str(),
                  f.offset, f.dso.c_str());
    }
  }
}

}  // namespace

int main(int argc, char **argv) {
  const char *workload = (argc > 1) ? argv[1] : "spin";
  int threads = (argc > 2) ? std::atoi(argv[2]) : 4;

  dst::bench::WorkloadHandle wh;
  wh.dso_path = "./build/libdoris_bench_dso.so";
  dst::bench::start_workload(workload, threads, &wh);
  std::this_thread::sleep_for(std::chrono::milliseconds(100));

  print("kill60",   dst::dump_all_threads_kill60());
  print("snapshot", dst::dump_all_threads_snapshot());

  dst::bench::stop_and_join(&wh);
  return 0;
}
