# VM perf/eBPF user-stack profiling case

This case is prepared for Phase 1-E. It is designed to run inside the QEMU
Ubuntu VM as root, through the Phase 1-A VM SSH contract.

Expected invocation after the VM skeleton is available:

```bash
vm/ubuntu-24.04/ssh.sh -- bash kernel_perf_ebpf_user_stack/perf_ebpf_vm/scripts/run_all.sh
```

If dependencies are not installed in the VM yet:

```bash
vm/ubuntu-24.04/ssh.sh -- bash kernel_perf_ebpf_user_stack/perf_ebpf_vm/scripts/install_deps.sh
vm/ubuntu-24.04/ssh.sh -- bash kernel_perf_ebpf_user_stack/perf_ebpf_vm/scripts/run_all.sh
```

The scripts are non-interactive and write outputs to `results/latest/`.
Curated VM runtime outputs from task #20 are checked in under
`outputs/vm_latest/`.

## Entrypoints

- `scripts/install_deps.sh`: Ubuntu guest dependency install, Grafana Alloy repo setup, Docker startup, VM-only sysctl relaxation.
- `scripts/build_target.sh`: builds a C++ target with FP and no-FP variants.
- `scripts/run_perf.sh`: runs perf FP/DWARF child, attach, and system-wide cases.
- `scripts/run_bpftrace.sh`: runs bpftrace on-CPU `ustack()` and sched-switch/off-CPU probes.
- `scripts/run_industry_profiler.sh`: runs local Pyroscope plus Grafana Alloy `pyroscope.ebpf` against the test target.
- `scripts/run_all.sh`: orchestrates the case.

## Semantics Under Test

The target creates CPU-burning, sleeping, and mutex-blocked threads. This makes
the distinction visible:

- `perf record -e cpu-clock:u` and `bpftrace profile:hz` are on-CPU/user sample routes.
- `sched:sched_switch` bpftrace is an event route for off-CPU evidence.
- Alloy `pyroscope.ebpf` is a continuous profiling route that forwards pprof-like profiles.

None of these are equivalent to a synchronous all-thread current stack snapshot.
