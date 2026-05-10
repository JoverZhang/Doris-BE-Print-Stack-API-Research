# ck-system-stack-trace-default

## What This Verifies

ClickHouse `system.stack_trace` built from source can collect native thread stack PCs through in-process directed signals and local unwind.

## Source Trace

release tag: TBD
commit: TBD

```text
TBD src/Storages/System/StorageSystemStackTrace.cpp:<line> <read/fill method>
  -> TBD enumerate /proc/self/task
    -> TBD send directed signal to target thread
      -> TBD src/Storages/System/StorageSystemStackTrace.cpp:<line> <signal handler>
        -> TBD src/Common/StackTrace.cpp:<line> StackTrace::<constructor>
          -> TBD src/Common/StackTrace.cpp:<line> StackTrace::tryCapture
            -> TBD libunwind local unwind
  -> output: system.stack_trace trace Array(UInt64)
```

## Run

```bash
just ck-system-stack-trace-default
```

## Inputs / Outputs

| input | output | meaning |
| --- | --- | --- |
| `queries/thread_stack.sql` | `queries/thread_stack.out` | Raw `system.stack_trace` query output. |
| `queries/thread_stack_fileline.sql` | `queries/thread_stack_fileline.out` | File/line output from source-built ClickHouse with matching debug info. |

## Minimal Impl

`minimal_impl/` must keep only the source-trace core: enumerate threads, send a directed signal, capture raw PCs with local unwind, coordinate with timeout/partial result, and print raw PCs. It must omit ClickHouse SQL, storage engine plumbing, access control, and production symbol caches.
