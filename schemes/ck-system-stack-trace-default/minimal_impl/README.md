# Minimal Impl

`directed_signal_unwind.cpp` retains the Source Trace core from ClickHouse `system.stack_trace`:

- enumerate Linux native threads through `/proc/self/task`;
- send a directed real-time signal with `rt_tgsigqueueinfo`;
- capture raw PCs in the signal handler with `unw_backtrace`;
- acknowledge through a pipe and use a poll timeout;
- print per-thread raw PC arrays.

It omits ClickHouse SQL, storage engine plumbing, `CurrentThread` query metadata, memory tracking, `SymbolIndex`, access control, and production symbol caches.

This is mechanism evidence only. It does not replace the ClickHouse source-build project run.

Run:

```bash
./minimal_impl/run.sh
```
