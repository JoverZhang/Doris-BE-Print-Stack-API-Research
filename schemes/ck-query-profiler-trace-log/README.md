# ck-query-profiler-trace-log

## What This Verifies

ClickHouse's sampling query profiler is a separate mechanism from `system.stack_trace`.
It periodically interrupts query threads with per-thread timers, captures a local stack
trace in the signal handler, and writes samples to `system.trace_log`.

This scheme runs the source-built ClickHouse server because `clickhouse local` does not
create `system.trace_log`.

## Source Trace

release tag: `v26.3.10.62-lts`
commit: `e1c11930c28196f954a93287e43c1aa112c8c607`

```text
programs/server/config.xml:1217 trace_log section
  -> enables system.trace_log when the server starts

src/Interpreters/ThreadStatusExt.cpp:655 ThreadStatus::initQueryProfiler
  -> src/Interpreters/ThreadStatusExt.cpp:657 returns if there is no TraceCollector
  -> src/Interpreters/ThreadStatusExt.cpp:668 checks query_profiler_real_time_period_ns
    -> src/Common/QueryProfiler.cpp:312 QueryProfilerReal uses CLOCK_MONOTONIC and SIGUSR1
  -> src/Interpreters/ThreadStatusExt.cpp:678 checks query_profiler_cpu_time_period_ns
    -> src/Common/QueryProfiler.cpp:325 QueryProfilerCPU uses CLOCK_THREAD_CPUTIME_ID and SIGUSR2

src/Common/QueryProfiler.cpp:234 QueryProfilerBase::QueryProfilerBase
  -> src/Common/QueryProfiler.cpp:245-256 installs the profiler signal handler
  -> src/Common/QueryProfiler.cpp:260-262 creates and arms the per-thread timer

src/Common/QueryProfiler.cpp:316 QueryProfilerReal::signalHandler
src/Common/QueryProfiler.cpp:329 QueryProfilerCPU::signalHandler
  -> src/Common/QueryProfiler.cpp:52 writeTraceInfo
    -> src/Common/QueryProfiler.cpp:89 copies ucontext_t
    -> src/Common/QueryProfiler.cpp:101 StackTrace(signal_context)
    -> src/Common/QueryProfiler.cpp:110 TraceSender::send(...)

src/Interpreters/TraceCollector.cpp:28 TraceCollector::TraceCollector
  -> src/Interpreters/TraceCollector.cpp:30 opens TraceSender pipe
  -> src/Interpreters/TraceCollector.cpp:35 makes the write end non-blocking
  -> src/Interpreters/TraceCollector.cpp:181 gets TraceLog
  -> src/Interpreters/TraceCollector.cpp:191-215 creates TraceLogElement and appends it
    -> output: system.trace_log rows with trace_type CPU or Real
```

Dump style: this is sampled profiling, not an on-demand current all-thread snapshot. It is
useful for performance investigation and flame graphs, but it is not the same product
surface as `SELECT * FROM system.stack_trace`.

## Run

```bash
just ck-query-profiler-trace-log
```

The run uses the default source-built ClickHouse binary from `ck-system-stack-trace`.
It starts a temporary local server, executes a CPU-heavy query with
`query_profiler_cpu_time_period_ns=1000000`, flushes logs, and reads samples from
`system.trace_log`.

## Inputs / Outputs

| input | output | meaning |
| --- | --- | --- |
| `commands/query_profiler_cpu.sh` | `commands/query_profiler_cpu.out` | Source-built server run, sampled CPU trace summary, and symbolized sample frames. |
| `queries/workload_cpu.sql` | `workload_result` section | CPU-heavy query executed with query profiler settings. |
| `queries/trace_log_summary.sql` | `trace_log_summary` section | Counts and frame depths grouped by `trace_type`. |
| `queries/trace_log_symbols.sql` | `trace_log_symbol_sample` section | Symbolized sample stacks through ClickHouse introspection functions. |

## Evidence Notes

- `clickhouse local` was probed and did not expose `system.trace_log`; the server path is required.
- Runtime evidence currently demonstrates the CPU timer path (`trace_type = 'CPU'`).
- The same source path supports real-time sampling with `query_profiler_real_time_period_ns`, which uses `SIGUSR1` and `CLOCK_MONOTONIC`.
- The profiler path does not use ptrace.
