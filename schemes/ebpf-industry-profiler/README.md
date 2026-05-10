# ebpf-industry-profiler

## What This Verifies

An industry eBPF profiler route, such as Alloy/Pyroscope or Parca, can collect profiling data in VM/root conditions, without becoming a live all-thread dump API.

## Source Trace

release tag: tool versions TBD by run output
commit: not applicable for binary packages unless source is checked out

```text
TBD commands/alloy_pyroscope.sh
  -> start local profile receiver
    -> start eBPF profiler component
      -> collect sampled user stacks
        -> write profile batches to receiver
  -> output: commands/alloy_pyroscope.out
```

## Run

```bash
just ebpf-industry-profiler
```

## Inputs / Outputs

| input | output | meaning |
| --- | --- | --- |
| `commands/alloy_pyroscope.sh` | `commands/alloy_pyroscope.out` | Industry profiler metrics and sample delivery evidence. |

## Minimal Impl

Reuse the controlled target shape from `ebpf-perf-bpftrace/minimal_impl/`. The key boundary must remain: profiling reproduced, `all_native_threads=no`, `live_api_fit=no`.
