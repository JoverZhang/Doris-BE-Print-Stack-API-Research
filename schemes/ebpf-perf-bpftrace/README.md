# ebpf-perf-bpftrace

## What This Verifies

perf and bpftrace can profile user stacks in a VM/root environment, while not providing a synchronous all-thread current stack snapshot.

## Source Trace

release tag: Linux/Ubuntu tool versions TBD by run output
commit: not applicable for distro tools

```text
TBD commands/perf_fp.sh
  -> perf record --call-graph fp
    -> kernel perf_event sampling
      -> user stack unwind from sampled on-CPU contexts
  -> output: commands/perf_fp.out

TBD commands/bpftrace_ustack.bt
  -> profile:hz probe
    -> ustack()
      -> sampled user stack aggregation
  -> output: commands/bpftrace_ustack.out
```

## Run

```bash
just ebpf-perf-bpftrace
```

## Inputs / Outputs

| input | output | meaning |
| --- | --- | --- |
| `commands/perf_fp.sh` | `commands/perf_fp.out` | perf frame-pointer callgraph evidence. |
| `commands/perf_dwarf.sh` | `commands/perf_dwarf.out` | perf DWARF callgraph evidence. |
| `commands/bpftrace_ustack.bt` | `commands/bpftrace_ustack.out` | bpftrace on-CPU user-stack sampling evidence. |
| `commands/bpftrace_offcpu.bt` | `commands/bpftrace_offcpu.out` | event/off-CPU evidence, not current stack snapshot. |

## Minimal Impl

`minimal_impl/` must provide a controlled target with CPU-running, sleeping, and blocked threads. Its output must demonstrate which threads profiling sees and which it misses.
