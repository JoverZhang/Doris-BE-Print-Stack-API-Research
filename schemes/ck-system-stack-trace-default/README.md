# ck-system-stack-trace-default

## What This Verifies

ClickHouse `system.stack_trace` built from source can collect native thread stack PCs through in-process directed signals and local unwind, and source-built debug info can resolve those PCs to symbols and file/line.

## Source Trace

release tag: `v26.3.10.62-lts`
commit: `e1c11930c28196f954a93287e43c1aa112c8c607`

```text
src/Storages/System/StorageSystemStackTrace.cpp:761 StorageSystemStackTrace::read
  -> src/Storages/System/StorageSystemStackTrace.cpp:690 ReadFromSystemStackTrace::initializePipeline creates StackTraceSource
    -> src/Storages/System/StorageSystemStackTrace.cpp:405 StackTraceSource opens /proc/self/task iterator
      -> src/Storages/System/StorageSystemStackTrace.cpp:453 StackTraceSource iterates selected thread ids
        -> src/Storages/System/StorageSystemStackTrace.cpp:503 prepares siginfo_t for a directed signal
          -> src/Storages/System/StorageSystemStackTrace.cpp:508 rt_tgsigqueueinfo(server_pid, tid, STACK_TRACE_SERVICE_SIGNAL, ...)
            -> src/Storages/System/StorageSystemStackTrace.cpp:120 signalHandler
              -> src/Storages/System/StorageSystemStackTrace.cpp:161 copies ucontext_t in the handler
                -> src/Storages/System/StorageSystemStackTrace.cpp:163 StackTrace(signal_context)
                  -> src/Common/StackTrace.cpp:470 StackTrace::StackTrace(const ucontext_t &)
                    -> src/Common/StackTrace.cpp:507 StackTrace::tryCapture
                      -> src/Common/StackTrace.cpp:512 unw_backtrace(frame_pointers.data(), FRAMEPOINTER_CAPACITY)
            -> src/Storages/System/StorageSystemStackTrace.cpp:518 waits on pipe with storage_system_stack_trace_pipe_read_timeout_ms
          -> src/Storages/System/StorageSystemStackTrace.cpp:551 gets captured frame pointers
            -> src/Storages/System/StorageSystemStackTrace.cpp:561 maps virtual address to object
              -> src/Storages/System/StorageSystemStackTrace.cpp:569 stores physical address in trace Array(UInt64)
                -> output: system.stack_trace columns at src/Storages/System/StorageSystemStackTrace.cpp:730-734

src/Common/SymbolIndex.cpp:41 describes DWARF debug info for file/line
  -> src/Common/SymbolIndex.cpp:55 says DWARF is used to display file names and line numbers
    -> src/Common/SymbolIndex.cpp:388-428 selects local .debug, /usr/lib/debug, build-id debug info, or the binary itself
      -> src/Common/SymbolIndex.cpp:703 SymbolIndex::load collects symbols for addressToSymbol/addressToLine
```

Dump style: `system.stack_trace` is an on-demand table read. It enumerates native Linux tasks under `/proc/self/task`, sends one directed real-time signal per thread, captures raw PCs in the signal handler through local unwind, coordinates through a pipe/timeout, and returns one row per responding thread. The raw `trace` column stores address offsets; human-readable symbols/file-lines come from SQL functions such as `addressToSymbol()` and `addressToLine()`.

## Run

```bash
rustup toolchain install nightly-2025-07-07
just ck-system-stack-trace-default
```

The Rust nightly is required by the ClickHouse source tree through `contrib/corrosion-cmake` / `contrib/wasmtime`. Without it, CMake fails before the `clickhouse` target build starts.

## Inputs / Outputs

| input | output | meaning |
| --- | --- | --- |
| `commands/source_build_probe.sh` | `commands/source_build_probe.out` | Source-build preflight: source tree, submodule, and Rust nightly requirements. |
| `commands/clickhouse_metadata.sh` | `commands/clickhouse_metadata.out` | Source-built binary version and build-id metadata when the source build succeeds. |
| `queries/thread_stack.sql` | `queries/thread_stack.out` | Raw `system.stack_trace` query output. |
| `queries/thread_stack_symbols.sql` | `queries/thread_stack_symbols.out` | Symbolized frames via `addressToSymbol()` and `demangle()`. |
| `queries/thread_stack_fileline.sql` | `queries/thread_stack_fileline.out` | File/line output from source-built ClickHouse with matching debug info. |
| `minimal_impl/directed_signal_unwind.cpp` | `minimal_impl/directed_signal_unwind.out` | Source-trace-derived minimal directed-signal raw PC demo. |

## Minimal Impl

`minimal_impl/` must keep only the source-trace core: enumerate threads, send a directed signal, capture raw PCs with local unwind, coordinate with timeout/partial result, and print raw PCs. It must omit ClickHouse SQL, storage engine plumbing, access control, and production symbol caches.

The minimal implementation is mechanism evidence only. It does not replace the ClickHouse source-build project run captured by the query outputs above.
