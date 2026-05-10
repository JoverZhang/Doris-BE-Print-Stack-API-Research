# ebpf-industry-profiler

## What This Verifies

Grafana Alloy `pyroscope.ebpf` can collect and send eBPF profiling data for a target process in the VM/root environment, but it remains continuous profiling, not a live all-thread dump API.

## Source Trace

release tag: Ubuntu 24.04 guest, Grafana Alloy `v1.16.1`, Docker `29.1.3`, local `grafana/pyroscope:latest` receiver
commit: binary/package route for the profiler tooling; controlled target source is in `minimal_impl/profile_target.cpp`

dump style: continuous pprof-style profile batches sent to a receiver. It records sampled stacks over an interval and exposes delivery metrics. It does not enumerate every target thread and does not synchronously dump all current stacks.

```text
commands/alloy_pyroscope.sh:38-47 start or reuse local Pyroscope receiver
  -> commands/alloy_pyroscope.sh:49-51 start controlled target process
    -> commands/alloy_pyroscope.sh:54-58 render and run Alloy config
      -> commands/pyroscope_ebpf.alloy.template:10 pyroscope.ebpf "target"
        -> commands/pyroscope_ebpf.alloy.template:17 forward_to pyroscope.write.local.receiver
          -> commands/alloy_pyroscope.sh:63-66 scrape Alloy/Pyroscope readiness and metrics
            -> commands/alloy_pyroscope.sh:68-85 writes commands/alloy_pyroscope.out

minimal_impl/profile_target.cpp:54 cpu_worker
  -> minimal_impl/profile_target.cpp:50 target_level_one
    -> minimal_impl/profile_target.cpp:46 target_level_two
      -> minimal_impl/profile_target.cpp:42 target_level_three
        -> minimal_impl/profile_target.cpp:32 target_leaf
          -> sampled profile data sent by Alloy/Pyroscope

minimal_impl/profile_target.cpp:63 sleep_worker
minimal_impl/profile_target.cpp:70 mutex_block_worker
  -> printed in target thread inventory
  -> boundary: profile delivery does not prove all sleeping/blocked current stacks
```

## Run

```bash
just ebpf-industry-profiler
```

From a separate worktree, point to an already-created VM helper if needed:

```bash
STACKTRACE_VM_SSH=/path/to/main/vm/ubuntu-24.04/ssh.sh just ebpf-industry-profiler
```

## Inputs / Outputs

| input | output | meaning |
| --- | --- | --- |
| `commands/alloy_pyroscope.sh` | `commands/alloy_pyroscope.out` | Alloy/Pyroscope eBPF profile delivery metrics and boundary evidence. |
| `commands/pyroscope_ebpf.alloy.template` | included in `commands/alloy_pyroscope.out` | Alloy config proving the eBPF component and write receiver path. |
| `minimal_impl/profile_target.cpp` | `minimal_impl/profile_target.out` | controlled target thread inventory. |

## Minimal Impl

`minimal_impl/` keeps the same controlled target shape as `ebpf-perf-bpftrace`: CPU-running workers, sleeping workers, mutex-blocked workers, and printed TIDs.

The profiler route is accepted only with this conclusion:

```text
PASS = VM/root profiling route reproduced; all_native_threads=no; live_api_fit=no
```
