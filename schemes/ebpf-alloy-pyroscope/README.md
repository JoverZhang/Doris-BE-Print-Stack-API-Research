# ebpf-alloy-pyroscope

## What This Verifies

Grafana Alloy `pyroscope.ebpf` can collect and send eBPF profiling data for a target process in the VM/root environment, but it remains continuous profiling, not a live all-thread dump API.

## Source Trace

release tag:
- Runtime guest: Ubuntu 24.04, Grafana Alloy `v1.16.1`, Docker `29.1.3`, local `grafana/pyroscope:latest` receiver.
- Upstream source trace: Grafana Alloy `v1.16.1`, commit `89d8237`.
- Alloy module dependency: `github.com/grafana/pyroscope/ebpf v0.4.11`, with `go.opentelemetry.io/ebpf-profiler` replaced by `github.com/grafana/opentelemetry-ebpf-profiler v0.0.202602-0.20260326091923-bd31a19190b9`.

commit: runtime binaries come from guest package/container routes; upstream file/function/line references below were checked against Alloy `v1.16.1`.

dump style: continuous pprof-style profile batches sent to a receiver. It records sampled stacks over an interval and exposes delivery metrics. It does not enumerate every target thread and does not synchronously dump all current stacks.

```text
Upstream Alloy/Pyroscope eBPF component path:
internal/component/all/all.go:172 imports/registers pyroscope.ebpf
  -> internal/component/pyroscope/ebpf/args.go:12 Arguments include forward_to, targets, collect_interval, sample_rate
    -> internal/component/pyroscope/ebpf/ebpf_linux.go:45 init registers component Name "pyroscope.ebpf"
      -> internal/component/pyroscope/ebpf/ebpf_linux.go:66 New
        -> internal/component/pyroscope/ebpf/ebpf_linux.go:89 args.Convert
          -> internal/component/pyroscope/ebpf/ebpf_linux.go:96 pyroscope.NewFanout
            -> internal/component/pyroscope/ebpf/ebpf_linux.go:138 reporter.NewPPROF
              -> internal/component/pyroscope/ebpf/ebpf_linux.go:149 callback res.sendProfiles
                -> internal/component/pyroscope/ebpf/ebpf_linux.go:178 Component.Run
                  -> internal/component/pyroscope/ebpf/ebpf_linux.go:188 controller.New
                    -> internal/component/pyroscope/ebpf/ebpf_linux.go:192 ctlr.Start
                      -> internal/component/pyroscope/ebpf/reporter/pprof.go:81 ReportTraceEvent accepts sampling/off-CPU/probe events
                        -> internal/component/pyroscope/ebpf/reporter/pprof.go:163 reportProfile
                          -> internal/component/pyroscope/ebpf/reporter/pprof.go:185 createProfile
                            -> internal/component/pyroscope/ebpf/send.go:16 sendProfiles
                              -> internal/component/pyroscope/ebpf/send.go:31-32 increments pprof counters
                                -> internal/component/pyroscope/ebpf/send.go:40-41 appender.Append sends raw pprof samples

Upstream readiness/metrics path:
internal/component/pyroscope/ebpf/ebpf_linux.go:289 checkTraceFS
  -> internal/component/pyroscope/ebpf/ebpf_linux.go:290-303 checks or mounts tracefs
    -> internal/component/pyroscope/ebpf/metrics.go:24 newMetrics
      -> internal/component/pyroscope/ebpf/metrics.go:38-52 defines pyroscope_ebpf_pprofs_total, pprofs_dropped_total, pprof_bytes_total, pprof_samples_total

Shared fixture path:
shared/ebpf/profile_target/profile_target.cpp:54 cpu_worker
  -> shared/ebpf/profile_target/profile_target.cpp:50 target_level_one
    -> shared/ebpf/profile_target/profile_target.cpp:46 target_level_two
      -> shared/ebpf/profile_target/profile_target.cpp:42 target_level_three
        -> shared/ebpf/profile_target/profile_target.cpp:32 target_leaf
          -> sampled profile data sent by Alloy/Pyroscope

shared/ebpf/profile_target/profile_target.cpp:63 sleep_worker
shared/ebpf/profile_target/profile_target.cpp:70 mutex_block_worker
  -> printed in target thread inventory
  -> boundary: profile delivery does not prove all sleeping/blocked current stacks

Local scheme path:
commands/alloy_pyroscope.sh:38-47 start or reuse local Pyroscope receiver
  -> commands/alloy_pyroscope.sh:49-51 start controlled target process
    -> commands/alloy_pyroscope.sh:54-58 render and run Alloy config
      -> helpers/pyroscope_ebpf.alloy.template:10 pyroscope.ebpf "target"
        -> helpers/pyroscope_ebpf.alloy.template:17 forward_to pyroscope.write.local.receiver
          -> commands/alloy_pyroscope.sh:63-66 scrape Alloy/Pyroscope readiness and metrics
            -> commands/alloy_pyroscope.sh:68-85 writes commands/alloy_pyroscope.out
```

## Run

```bash
just ebpf-alloy-pyroscope
```

From a separate worktree, point to an already-created VM helper if needed:

```bash
STACKTRACE_VM_SSH=/path/to/main/vm/ubuntu-24.04/ssh.sh just ebpf-alloy-pyroscope
```

## Inputs / Outputs

| input | output | meaning |
| --- | --- | --- |
| `commands/alloy_pyroscope.sh` | `commands/alloy_pyroscope.out` | Alloy/Pyroscope eBPF profile delivery metrics and boundary evidence. |
| `shared/ebpf/profile_target/profile_target.cpp` | `minimal_impl/profile_target.out` | controlled shared target thread inventory. |

## Minimal Impl

`minimal_impl/` uses the shared target in `shared/ebpf/profile_target/`, the same controlled target shape as `ebpf-perf-bpftrace`: CPU-running workers, sleeping workers, mutex-blocked workers, and printed TIDs.

The profiler route is accepted only with this conclusion:

```text
PASS = VM/root profiling route reproduced; all_native_threads=no; live_api_fit=no
```
