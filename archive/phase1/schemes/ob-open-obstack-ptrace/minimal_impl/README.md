# Minimal Impl

This is a minimal external attach / remote unwind implementation derived from
the open-source `oceanbase/obstack` path:

```text
target pid
  -> open /proc/<pid>/task
  -> for each tid:
       ptrace(PTRACE_ATTACH, tid)
       waitpid(tid, ..., __WALL)
       _UPT_create(tid)
       unw_init_remote(...)
       repeat unw_get_reg(UNW_REG_IP) + unw_step
       ptrace(PTRACE_DETACH, tid)
  -> output per-thread raw PCs
```

It omits symbolization, aggregation, BFD/LLVM, and packaging. It proves the
remote-unwind mechanics only.
