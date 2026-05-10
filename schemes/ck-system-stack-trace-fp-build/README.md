# ck-system-stack-trace-fp-build

## What This Verifies

ClickHouse source build under frame-pointer-preserving build conditions can be compared against the default source build without changing the user-facing `system.stack_trace` API.

## Source Trace

release tag: `v26.3.10.62-lts`
commit: `e1c11930c28196f954a93287e43c1aa112c8c607`

```text
src/Storages/System/StorageSystemStackTrace.cpp:761 StorageSystemStackTrace::read
  -> src/Storages/System/StorageSystemStackTrace.cpp:690 ReadFromSystemStackTrace::initializePipeline creates StackTraceSource
    -> src/Storages/System/StorageSystemStackTrace.cpp:405 StackTraceSource opens /proc/self/task iterator
      -> src/Storages/System/StorageSystemStackTrace.cpp:453 StackTraceSource iterates selected thread ids
        -> src/Storages/System/StorageSystemStackTrace.cpp:508 rt_tgsigqueueinfo(server_pid, tid, STACK_TRACE_SERVICE_SIGNAL, ...)
          -> src/Storages/System/StorageSystemStackTrace.cpp:120 signalHandler
            -> src/Storages/System/StorageSystemStackTrace.cpp:163 StackTrace(signal_context)
              -> src/Common/StackTrace.cpp:470 StackTrace::StackTrace(const ucontext_t &)
                -> src/Common/StackTrace.cpp:507 StackTrace::tryCapture
                  -> src/Common/StackTrace.cpp:512 unw_backtrace(frame_pointers.data(), FRAMEPOINTER_CAPACITY)
        -> src/Storages/System/StorageSystemStackTrace.cpp:518 waits on pipe timeout
          -> src/Storages/System/StorageSystemStackTrace.cpp:569 stores physical address in trace Array(UInt64)
            -> output: same `system.stack_trace` user API as the default scheme

CMakeLists.txt:309 declares DISABLE_OMIT_FRAME_POINTER
  -> CMakeLists.txt:312 checks DISABLE_OMIT_FRAME_POINTER
    -> CMakeLists.txt:313-315 appends -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer to CXX/C/ASM flags
```

Dump style: this is still the ClickHouse `system.stack_trace` table and not a second API. The scheme only changes source build flags to preserve frame pointers and then compares query output and a minimal backend control against the default build.

## Run

```bash
just ck-system-stack-trace-fp-build
```

## Inputs / Outputs

| input | output | meaning |
| --- | --- | --- |
| `commands/source_build_probe.sh` | `commands/source_build_probe.out` | Source-build blocker evidence: clone command, elapsed/space/submodule stop point, CMake submodule error. |
| `queries/thread_stack.sql` | `queries/thread_stack.out` | Stack trace output from the source frame-pointer build. |
| `queries/thread_stack_fileline.sql` | `queries/thread_stack_fileline.out` | File/line output from the source frame-pointer build. |
| `minimal_impl/fp_vs_unwind.cpp` | `minimal_impl/fp_vs_unwind.out` | Minimal frame-pointer walker versus libunwind control. |

## Minimal Impl

`minimal_impl/` must keep a small frame-pointer walker versus libunwind comparison. It must state that this is a build-condition/backend comparison, not a second ClickHouse user API.

The minimal implementation is mechanism evidence only. It does not replace the ClickHouse source-build project run, which is currently blocked by source checkout/submodule initialization cost in this environment.
