#pragma once

#include <atomic>
#include <string>
#include <thread>
#include <vector>

namespace doris::stacktrace::bench {

struct WorkloadHandle {
  std::vector<std::thread>  threads;
  std::atomic<bool>         stop{false};
  std::string               dso_path;  // for dlopen workload
};

void start_workload(const std::string &name, int n, WorkloadHandle *out);
void stop_and_join(WorkloadHandle *h);

}  // namespace doris::stacktrace::bench
