# ck-system-stack-trace

## What This Verifies

ClickHouse `system.stack_trace` built from source can collect native thread stack PCs through in-process directed signals and local unwind. The scheme records two build variants: the default source build and a frame-pointer-preserving source build. Both variants use the same ClickHouse user-facing `system.stack_trace` API.

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

CMakeLists.txt:309 declares DISABLE_OMIT_FRAME_POINTER
  -> CMakeLists.txt:312 checks DISABLE_OMIT_FRAME_POINTER
    -> CMakeLists.txt:313-315 appends -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer to CXX/C/ASM flags
      -> variant: fp-build only; output remains the same system.stack_trace table
```

Dump style: `system.stack_trace` is an on-demand table read. It enumerates native Linux tasks under `/proc/self/task`, sends one directed real-time signal per thread, captures raw PCs in the signal handler through local unwind, coordinates through a pipe/timeout, and returns one row per responding thread. The raw `trace` column stores address offsets; human-readable symbols/file-lines come from SQL functions such as `addressToSymbol()` and `addressToLine()`.

The frame-pointer build is a build-condition/backend comparison only. It is not a second ClickHouse user API and should not be counted as a separate research route.

## Run

```bash
rustup toolchain install nightly-2025-07-07
just ck-system-stack-trace

# Optional: run one variant only.
CK_VARIANT=default just ck-system-stack-trace
CK_VARIANT=fp-build just ck-system-stack-trace
```

The Rust nightly is required by the ClickHouse source tree through `contrib/corrosion-cmake` / `contrib/wasmtime`. Without it, CMake fails before the `clickhouse` target build starts.

## Inputs / Outputs

| input | output | meaning |
| --- | --- | --- |
| `variants/default/commands/source_build_probe.sh` | `variants/default/commands/source_build_probe.out` | Default source-build preflight: source tree, submodule, and Rust nightly requirements. |
| `variants/default/commands/clickhouse_metadata.sh` | `variants/default/commands/clickhouse_metadata.out` | Default source-built binary version and build-id metadata. |
| `variants/default/queries/thread_stack.sql` | `variants/default/queries/thread_stack.out` | Raw `system.stack_trace` query output from the default source build. |
| `variants/default/queries/thread_stack_symbols.sql` | `variants/default/queries/thread_stack_symbols.out` | Symbolized frames via `addressToSymbol()` and `demangle()` from the default source build. |
| `variants/default/queries/thread_stack_fileline.sql` | `variants/default/queries/thread_stack_fileline.out` | File/line output from the default source build with matching debug info. |
| `variants/fp-build/commands/source_build_probe.sh` | `variants/fp-build/commands/source_build_probe.out` | Frame-pointer source-build preflight. |
| `variants/fp-build/commands/clickhouse_metadata.sh` | `variants/fp-build/commands/clickhouse_metadata.out` | Frame-pointer source-built binary version and build-id metadata. |
| `variants/fp-build/queries/thread_stack.sql` | `variants/fp-build/queries/thread_stack.out` | Raw `system.stack_trace` query output from the frame-pointer source build. |
| `variants/fp-build/queries/thread_stack_fileline.sql` | `variants/fp-build/queries/thread_stack_fileline.out` | File/line output from the frame-pointer source build. |
| `minimal_impl/default/directed_signal_unwind.cpp` | `minimal_impl/default/directed_signal_unwind.out` | Source-trace-derived minimal directed-signal raw PC demo for the default variant. |
| `minimal_impl/fp-build/fp_vs_unwind.cpp` | `minimal_impl/fp-build/fp_vs_unwind.out` | Minimal frame-pointer walker versus libunwind control for the frame-pointer build condition. |

## Minimal Impl

`minimal_impl/default/` keeps only the source-trace core: enumerate threads, send a directed signal, capture raw PCs with local unwind, coordinate with timeout/partial result, and print raw PCs. It omits ClickHouse SQL, storage engine plumbing, access control, and production symbol caches. It intentionally does not force `-fno-omit-frame-pointer`.

`minimal_impl/fp-build/` keeps a small frame-pointer walker versus libunwind comparison. This is a build-condition/backend comparison, not a second ClickHouse user API.

The minimal implementations are mechanism evidence only. They do not replace the ClickHouse source-build project run captured by the query outputs above.
