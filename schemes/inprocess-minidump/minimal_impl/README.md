# Minimal Implementation

`inprocess_minidump.cpp` is a Linux x86_64-only diagnostic artifact prototype.

It demonstrates this sequence:

1. initialize a signal handler and two worker threads;
2. the normal thread sends a directed signal to each worker;
3. each worker's signal handler captures only register state and bounded stack
   bytes, then writes an acknowledgement containing the request sequence;
4. the worker remains parked until the normal thread copies the snapshot and
   performs handler-outside unwind from the saved signal `ucontext_t`;
5. the normal thread prints each worker's stack trace and then releases the
   parked worker.

The handler does not call libunwind, `dladdr`, demangling, allocation, or
formatted I/O. The target is compiled with default frame-pointer behavior and
does not use `-fno-omit-frame-pointer`.

The artifact capture is the primary evidence: x86_64 registers, saved
`ucontext_t`, bounded stack bytes, truncation status, and request-sequenced ack.
The stack bytes are captured for minidump-lite evidence and future detached
analysis; this minimal implementation does not do frame-pointer walking and does
not claim a full offline DWARF unwind from copied bytes.
