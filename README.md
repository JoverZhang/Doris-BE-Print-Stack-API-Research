# Stacktrace Research Repro

Reproducible research repo for C/C++ service stack tracing techniques.

This repo separates complete live stack-dump designs from capture backends and auxiliary tooling:

- complete solution: thread enumeration, trigger, capture, coordination, output, symbolization;
- capture backend: libunwind, frame-pointer walk, gperftools stacktrace, libgcc unwind;
- auxiliary tooling: symbolization, profiling, crash/minidump, current-thread helpers.

## Phase 1 Scope

Phase 1 validates:

- ClickHouse `system.stack_trace`, including debug-info file/line output and FP/no-FP controlled comparison.
- OceanBase observer `kill -60`, OCP `obstack_x86_64`, and open-source `oceanbase/obstack` as separate cases.
- perf/eBPF inside a QEMU VM with root privileges, including at least one industry profiler route.

Other techniques remain in `reference_checklist/` until explicitly promoted.

## Layout

```text
repos/
in_process_directed_signal_with_local_unwind/
in_process_directed_signal_raw_with_frame_pointer_walk/
external_ptrace_remote_unwind/
runtime_aware_logical_task_stack/
kernel_perf_ebpf_user_stack/
crash_minidump_and_symbolization/
reference_checklist/
scripts/
vm/
templates/
```

## Workflow

Use separate branches or `git worktree` directories per task. Each owner should edit only their assigned case directory plus shared files after coordination.

Each case must provide:

- `case.yaml`
- `README.md`
- `scripts/build.sh`
- `scripts/run.sh`
- `scripts/clean.sh`
- `outputs/`
- `report.md`

Run:

```bash
just --list
just env
just validate
```

