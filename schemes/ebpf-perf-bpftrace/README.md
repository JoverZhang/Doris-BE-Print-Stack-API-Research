# ebpf-perf-bpftrace

## What This Verifies

`perf` and `bpftrace` can collect user stack samples in a VM/root-capable environment, but the result is profiling/event evidence, not a synchronous all-native-thread current stack snapshot.

## Source Trace

release tag: Ubuntu 24.04 guest, Linux `6.8.0-111-generic`, `perf version 6.8.12`, `bpftrace v0.20.2`
commit: distro packages; not a project source checkout in this scheme

dump style: sampled callchain/profile output. It records stacks observed at perf/eBPF events. It does not enumerate all target threads and does not force every target thread to report its current stack.

```text
commands/perf_fp.sh:13 perf record -F 99 -e cpu-clock:u --call-graph fp,64
  -> perf_event sampling on CPU-clock user events
    -> sampled target context unwinds user stack with frame pointers
      -> commands/perf_fp.sh:25-43 writes commands/perf_fp.out

commands/perf_dwarf.sh:13 perf record -F 99 -e cpu-clock:u --call-graph dwarf,8192
  -> perf_event sampling on CPU-clock user events
    -> sampled target context unwinds user stack with DWARF/unwind metadata
      -> commands/perf_dwarf.sh:25-43 writes commands/perf_dwarf.out

commands/bpftrace_ustack.bt:1 profile:hz:49
  -> commands/bpftrace_ustack.bt:4 ustack(20)
    -> sampled on-CPU user stack aggregation for the target PID
      -> commands/run_bpftrace_ustack.sh:26-42 writes commands/bpftrace_ustack.out

commands/bpftrace_offcpu.bt:1 tracepoint:sched:sched_switch
  -> commands/bpftrace_offcpu.bt:4 ustack(20)
    -> event-based stack aggregation when matching threads leave CPU
      -> commands/run_bpftrace_offcpu.sh:26-43 writes commands/bpftrace_offcpu.out

minimal_impl/profile_target.cpp:54 cpu_worker
  -> minimal_impl/profile_target.cpp:50 target_level_one
    -> minimal_impl/profile_target.cpp:46 target_level_two
      -> minimal_impl/profile_target.cpp:42 target_level_three
        -> minimal_impl/profile_target.cpp:32 target_leaf
          -> sampled stack symbol sequence in commands/*.out

minimal_impl/profile_target.cpp:63 sleep_worker
minimal_impl/profile_target.cpp:70 mutex_block_worker
  -> printed in target thread inventory
  -> expected negative evidence: not covered by on-CPU samples as current stacks
```

## Run

```bash
just ebpf-perf-bpftrace
```

From a separate worktree, point to an already-created VM helper if needed:

```bash
STACKTRACE_VM_SSH=/path/to/main/vm/ubuntu-24.04/ssh.sh just ebpf-perf-bpftrace
```

## Inputs / Outputs

| input | output | meaning |
| --- | --- | --- |
| `commands/perf_fp.sh` | `commands/perf_fp.out` | perf frame-pointer callgraph evidence on the FP target. |
| `commands/perf_dwarf.sh` | `commands/perf_dwarf.out` | perf DWARF callgraph evidence on the no-FP target. |
| `commands/bpftrace_ustack.bt` | `commands/bpftrace_ustack.out` | bpftrace on-CPU user-stack sampling evidence. |
| `commands/bpftrace_offcpu.bt` | `commands/bpftrace_offcpu.out` | sched-switch event/off-CPU evidence, not a current stack snapshot. |
| `minimal_impl/profile_target.cpp` | `minimal_impl/profile_target.out` | controlled target thread inventory. |

## Minimal Impl

`minimal_impl/` keeps only the source-trace nodes needed to prove the semantic boundary:

- CPU workers with a stable symbol chain: `cpu_worker -> target_level_one -> target_level_two -> target_level_three -> target_leaf`.
- Sleeping and mutex-blocked workers with printed TIDs.
- FP and no-FP build variants.

It omits any all-thread dump mechanism. The expected conclusion is:

```text
PASS = VM/root profiling route reproduced; all_native_threads=no; live_api_fit=no
```
