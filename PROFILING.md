# Profiling Notes

This file tracks sampled profiling references that are useful background for the
Doris stack trace research, but are not primary candidates for the Print Stack
API.

The distinction is:

- stack dump: answer "where is every target thread right now?"
- profiling: answer "where did execution spend time over an interval?"

## Current Profiling Schemes

| Area | Scheme | Status | Why It Is Separate |
| --- | --- | --- | --- |
| ClickHouse query profiler / `system.trace_log` | `schemes/ck-query-profiler-trace-log/` | Built and reproduced from source. | Sampled CPU/real-time traces for queries; not an on-demand all-thread snapshot. |
| perf / bpftrace | `schemes/ebpf-perf-bpftrace/` | Reproduced in a VM/root-capable environment. | Event/profile samples; does not force every target thread to report its current stack. |
| Grafana Alloy / Pyroscope eBPF | `schemes/ebpf-alloy-pyroscope/` | Reproduced in a VM/root-capable environment. | Continuous profile batches; useful for flame graphs, not live all-thread dump. |

## ClickHouse Query Profiler

ClickHouse's query profiler writes samples to `system.trace_log`. It is separate
from `system.stack_trace`.

Source shape:

```text
ThreadStatus::initQueryProfiler
  -> QueryProfilerReal for query_profiler_real_time_period_ns
     -> CLOCK_MONOTONIC + SIGUSR1
  -> QueryProfilerCPU for query_profiler_cpu_time_period_ns
     -> CLOCK_THREAD_CPUTIME_ID + SIGUSR2
  -> QueryProfiler signal handler captures StackTrace(signal_context)
  -> TraceSender writes to TraceCollector pipe
  -> TraceCollector appends rows to system.trace_log
```

Evidence:

- `schemes/ck-query-profiler-trace-log/commands/query_profiler_cpu.out`
- reproduced with source-built ClickHouse server
- `clickhouse local` was probed and does not expose `system.trace_log`, so this
  scheme starts a temporary server

Chronology:

| Item | Public evidence in this workspace |
| --- | --- |
| `system.trace_log` write path | ClickHouse commit `5c54bbb7506803899f45d0e73f8f7a2a9e5b0c4c`, 2019-02-03. |
| CPU timer support | ClickHouse commit `6367e15e4eea5cd1ef49d51ef7a5953cbecd85ea`, 2019-03-04. |

## eBPF / perf / Pyroscope

The eBPF schemes are valuable as profiling baselines and as negative evidence
for the stack dump API shape:

- they can collect useful user-stack samples
- they are good for hotspot analysis and flame graphs
- they do not synchronously enumerate all native threads
- sleeping or blocked threads are not guaranteed to appear as current stacks

These schemes should stay out of the primary stack dump comparison unless the
research goal changes from "print current stacks" to "continuous profiling".
