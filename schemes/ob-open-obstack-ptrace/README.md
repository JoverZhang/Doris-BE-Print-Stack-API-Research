# ob-open-obstack-ptrace

## What This Verifies

Open-source `oceanbase/obstack` built from source can perform external ptrace/remote-unwind stack collection.

## Source Trace

release tag: no release tag published; public source is `master`
commit: `d91edd6d882a33b69164f8d3e809092408da3a33`

```text
src/main.cpp:262 main
  -> src/main.cpp:271 get_options parses target pid/options
  -> src/main.cpp:282 iter_task(CONF.pid, ...)

src/main.cpp:177 iter_task
  -> src/main.cpp:188 open("/proc/%d/task/")
  -> src/main.cpp:196 syscall(SYS_getdents64, ...)
  -> src/main.cpp:212-214 get_th_name(tid, ...) and callback

src/main.cpp:290 fork coreprocess
  -> child: src/main.cpp:356 unw_create_addr_space(&_UPT_accessors, 0)
  -> child: src/main.cpp:371-372 ptrace(PTRACE_ATTACH, t->tid_)
  -> child: src/main.cpp:388 wait4(t->tid_, ..., __WALL, ...)
  -> child: src/main.cpp:405 _UPT_create(t->tid_)
  -> child: src/main.cpp:413 unw_init_remote(&c, as, ui)
  -> child: src/main.cpp:418 unw_get_reg(&c, UNW_REG_IP, &uip)
  -> child: src/main.cpp:423 unw_step(&c)
  -> child: src/main.cpp:381 DEFER ptrace(PTRACE_DETACH, t->tid_, ...)

src/main.cpp:328 ObStack os(CONF.pid)
  -> src/main.cpp:331 os.add_bt(...)
  -> src/main.cpp:334 os.stack_it()

src/obstack.cpp:223 ObStack::stack_it
  -> src/obstack.cpp:226 read_maps(pid_)
  -> src/obstack.cpp:227 load_maps(bfd_cache)
  -> src/obstack.cpp:228-241 no_parse raw address output path
  -> src/obstack.cpp:275 LLVMDwarfDump(file.c_str())
  -> src/obstack.cpp:279 llvmdwdump.addr2line(...)
  -> src/obstack.cpp:284 bfd_cache.addr2symbol(...)
  -> src/obstack.cpp:292 gen_result()
  -> output: per-thread raw PC / symbolized stack, optionally aggregated
```

## Run

```bash
just ob-open-obstack-ptrace
```

## Inputs / Outputs

| input | output | meaning |
| --- | --- | --- |
| `commands/attach_synthetic.sh` | `commands/attach_synthetic.out` | Attach to a controlled synthetic target. |
| `commands/attach_observer.sh` | `commands/attach_observer.out` | Attach to real observer if allowed; blocker must be explicit if not. |
| `commands/source_build_probe.sh` | `commands/source_build_probe.out` | Current open-source obstack build blocker. |

## Minimal Impl

`minimal_impl/` keeps `/proc/<pid>/task` enumeration, `PTRACE_ATTACH`, `waitpid`, `_UPT_create`, `unw_init_remote`, `unw_get_reg`, `unw_step`, and `PTRACE_DETACH`.

It omits BFD/LLVM symbolization, aggregation, CLI options, RPM packaging, and any claim of low-disturbance online suitability.
