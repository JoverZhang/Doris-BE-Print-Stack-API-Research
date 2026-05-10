# VM Runtime Evidence

Captured for task #20 inside the task #16 Ubuntu 24.04 QEMU/KVM VM.

Key files:

- `environment.txt`: guest kernel, tool versions, and perf/eBPF sysctls.
- `perf_summary.txt`: perf FP/DWARF child, attach, and system-wide runs.
- `bpftrace_summary.txt`: bpftrace on-CPU and sched-switch/off-CPU runs.
- `industry_profiler_summary.txt`: Grafana Alloy `pyroscope.ebpf` against local Pyroscope.
- `alloy_metrics.prom`: raw Alloy metrics showing profiles sent to Pyroscope.

Large raw perf `.data` and `.script` artifacts are intentionally not checked in;
the summaries contain the command outcomes and representative callchains needed
for Phase 1 review.
