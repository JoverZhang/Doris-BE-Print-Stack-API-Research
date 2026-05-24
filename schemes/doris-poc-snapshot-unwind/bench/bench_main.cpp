#include "doris_stacktrace.h"
#include "workloads.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <thread>
#include <vector>

namespace dst = doris::stacktrace;

namespace {

struct Args {
  std::string impl     = "snapshot";
  std::string workload = "spin";
  int         threads  = 4;
  int         iters    = 200;
  int         warmup   = 20;
  int         timeout_ms = 100;
  std::string out      = "bench.csv";
  std::string dso      = "./libdoris_bench_dso.so";
  bool        header   = false;
};

bool starts_with(const std::string &s, const char *p) {
  std::size_t n = std::strlen(p);
  return s.size() >= n && std::memcmp(s.data(), p, n) == 0;
}

Args parse(int argc, char **argv) {
  Args a;
  for (int i = 1; i < argc; ++i) {
    std::string s = argv[i];
    if      (starts_with(s, "--impl="))       a.impl       = s.substr(7);
    else if (starts_with(s, "--workload="))   a.workload   = s.substr(11);
    else if (starts_with(s, "--threads="))    a.threads    = std::atoi(s.c_str() + 10);
    else if (starts_with(s, "--iters="))      a.iters      = std::atoi(s.c_str() + 8);
    else if (starts_with(s, "--warmup="))     a.warmup     = std::atoi(s.c_str() + 9);
    else if (starts_with(s, "--timeout-ms=")) a.timeout_ms = std::atoi(s.c_str() + 13);
    else if (starts_with(s, "--out="))        a.out        = s.substr(6);
    else if (starts_with(s, "--dso="))        a.dso        = s.substr(6);
    else if (s == "--write-header")           a.header     = true;
    else {
      std::fprintf(stderr, "unknown arg: %s\n", s.c_str());
      std::exit(2);
    }
  }
  return a;
}

std::uint64_t pctile(std::vector<std::uint64_t> &v, double p) {
  if (v.empty()) return 0;
  std::size_t idx = static_cast<std::size_t>(p * (v.size() - 1));
  std::nth_element(v.begin(), v.begin() + idx, v.end());
  return v[idx];
}

}  // namespace

int main(int argc, char **argv) {
  Args a = parse(argc, argv);

  // Pre-load the test DSO from the dlopen workload so that the file exists
  // even before the bench actually starts running it. The cleaner approach is
  // to validate the path early — if it's missing for the dlopen workload, we
  // fall back to keeping spin behavior.
  std::filesystem::path dso_full(a.dso);
  if (!dso_full.is_absolute()) dso_full = std::filesystem::absolute(dso_full);

  dst::bench::WorkloadHandle wh;
  wh.dso_path = dso_full.string();
  dst::bench::start_workload(a.workload, a.threads, &wh);
  std::this_thread::sleep_for(std::chrono::milliseconds(50));

  auto run_dump = [&]() {
    if (a.impl == "kill60") {
      return dst::dump_all_threads_kill60(std::chrono::milliseconds(a.timeout_ms));
    }
    return dst::dump_all_threads_snapshot(std::chrono::milliseconds(a.timeout_ms));
  };

  // Warmup. Also primes the DSO cache and any first-touch costs.
  for (int i = 0; i < a.warmup; ++i) (void)run_dump();

  std::ofstream out(a.out, std::ios::app);
  if (a.header) {
    out << "impl,workload,thread_count,copy_bytes,iter,e2e_ns,"
           "pause_p50_ns,pause_p99_ns,dispatch_p50_ns,dispatch_p99_ns,"
           "ok_count,truncated_count,timed_out_count,unregistered_count,error_count\n";
  }

  for (int i = 0; i < a.iters; ++i) {
    auto r = run_dump();
    std::vector<std::uint64_t> pause, dispatch;
    pause.reserve(r.threads.size());
    dispatch.reserve(r.threads.size());
    std::size_t ok = 0, trunc = 0, to = 0, unreg = 0, err = 0;
    for (const auto &t : r.threads) {
      switch (t.status) {
        case dst::DumpStatus::OK:           ++ok; break;
        case dst::DumpStatus::TIMED_OUT:    ++to; break;
        case dst::DumpStatus::UNREGISTERED: ++unreg; break;
        case dst::DumpStatus::ERROR:        ++err; break;
      }
      if (t.truncated) ++trunc;
      if (t.status == dst::DumpStatus::OK) {
        pause.push_back(static_cast<std::uint64_t>(t.handler_ns.count()));
        dispatch.push_back(static_cast<std::uint64_t>(t.dispatch_ns.count()));
      }
    }
    std::uint64_t p50 = pctile(pause,    0.50);
    std::uint64_t p99 = pctile(pause,    0.99);
    std::uint64_t d50 = pctile(dispatch, 0.50);
    std::uint64_t d99 = pctile(dispatch, 0.99);

    out << a.impl << "," << a.workload << "," << a.threads << ","
        << dst::kStackCopyBytes << "," << i << "," << r.elapsed_ns.count() << ","
        << p50 << "," << p99 << "," << d50 << "," << d99 << ","
        << ok << "," << trunc << "," << to << "," << unreg << "," << err << "\n";
  }

  dst::bench::stop_and_join(&wh);
  return 0;
}
