# inprocess-minidump

## What This Verifies

A normal thread can trigger two worker threads to capture x86_64 register state
and bounded stack bytes in a signal handler, collect those snapshots, and then
attempt stack unwinding outside the handler.

## Source Trace

release tag: repo-owned design
commit: current repo commit for this scheme

```text
minimal_impl/inprocess_minidump.cpp:install_capture_handler
  -> capture_handler
    -> save x86_64 gregs from ucontext_t
    -> copy at most 64 KiB from interrupted RSP to the registered stack high address
    -> write Ack{slot_index, sequence, status, copied_len}
  -> capture_worker
    -> rt_tgsigqueueinfo(normal pid, worker tid, SIGURG, slot pointer)
    -> wait for matching request sequence ack
    -> copy CaptureSlot into WorkerSnapshot artifact
  -> unwind_snapshot
    -> libunwind from saved ucontext while the interrupted worker is still parked
    -> print stack frames or explicit failure outside the signal handler
```

Dump style: this is a diagnostic artifact route, not an online text-stack API.
The handler captures raw evidence only. Unwinding and symbolization happen later
on the normal thread after the worker handler has acknowledged the snapshot.
This minimal implementation keeps the interrupted worker parked until the normal
thread finishes the handler-outside unwind, so libunwind can consume the saved
ucontext without doing any complex work inside the handler. The bounded copied
stack is still part of the artifact and is reported, but this first scheme does
not claim a detached offline DWARF unwind over copied bytes.

## Run

```bash
just inprocess-minidump
```

## Inputs / Outputs

| input | output | meaning |
| --- | --- | --- |
| `minimal_impl/inprocess_minidump.cpp` | `minimal_impl/inprocess_minidump.out` | x86_64 signal snapshot artifact plus handler-outside unwind attempt for two workers. |

## Minimal Impl

The minimal implementation keeps initialization, normal-thread directed signal
trigger, two worker thread snapshots, request-sequenced ack, bounded stack copy,
and handler-outside unwind.

The handler intentionally omits libunwind, `dladdr`, demangling, allocation,
formatted I/O, and frame-pointer walking. The target uses default compiler
frame-pointer behavior and does not enable `-fno-omit-frame-pointer`.

The primary success criteria are: both workers produce complete snapshots, ack
messages include the matching request sequence, and the normal thread prints
stack traces outside the handler. The copied stack bytes are retained as bounded
artifact evidence for a future detached analyzer; they are not used as a
frame-pointer walk and are not presented as proof of a full offline minidump
unwinder.
