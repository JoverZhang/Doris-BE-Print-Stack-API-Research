# libunwind signal reentry deadlock reproducer

This directory contains one program that reproduces the signal-handler deadlock
around libunwind's `unw_backtrace()` path to glibc `dl_iterate_phdr()`.

## Build and Run

Build instructions are in [BUILD.md](BUILD.md).

Run the reproducer from this directory:

```bash
./libunwind_signal_deadlock_reproducer
```

Expected result:

```text
S9 result: libunwind signal reentry deadlock reproduced
```

The reproducer exits with `124` after it confirms the deadlock.

Debugger workflows are in [DEBUGGING.md](DEBUGGING.md).

## Critical Path

The deadlock is the lock cycle below:

1. `T1` enters `dl_iterate_phdr()` and holds glibc's loader lock:

   - glibc `dl_iterate_phdr()` takes the loader lock. [source](https://github.com/bminor/glibc/blob/master/elf/dl-iteratephdr.c#L38-L39)

2. `T2` enters libunwind from a signal handler. It holds libunwind's
   `cache->lock`, then goes to `dl_iterate_phdr()` and waits for the loader
   lock held by `T1`:

   - `get_rs_cache()` acquires `cache->lock`. [source](https://github.com/libunwind/libunwind/blob/v1.6.2/src/dwarf/Gparser.c#L595-L618)
   - `find_reg_state()` calls `fetch_proc_info()` on cache miss. [source](https://github.com/libunwind/libunwind/blob/v1.6.2/src/dwarf/Gparser.c#L908-L925)
   - `dwarf_find_proc_info()` calls `dl_iterate_phdr()`. [source](https://github.com/libunwind/libunwind/blob/v1.6.2/src/dwarf/Gfind_proc_info-lsb.c#L806-L808)

3. `T1` receives a signal while still inside the outer `dl_iterate_phdr()`
   callback. Its signal handler runs libunwind and tries to take the same
   libunwind `cache->lock`, which is still held by `T2`.

In short:

```text
T1 outer dl_iterate_phdr   holds glibc loader lock, waits for T1 handler to return
T2 handler/libunwind       holds libunwind cache lock, waits for glibc loader lock
T1 handler/libunwind       waits for libunwind cache lock
```

## How It Reproduces

There are three threads:

- `t1`: enters `dl_iterate_phdr()`.
- `t2`: waits for a realtime signal.
- `main`: sends signals and controls the ordering.

The exact sequence is:

1. `S1`: `t1` calls outer `dl_iterate_phdr` and stays inside its callback. This holds
   glibc's loader lock.
2. `S2`: `t2` waits for a realtime signal.
3. `S3`: `main` signals `t2`.
4. `S4`: `t2` enters the signal handler and calls libunwind `unw_backtrace()`.
5. `S5`: libunwind takes its DWARF register-state cache lock, then calls
   `dl_iterate_phdr`; `t2` blocks on the loader lock held by `t1`.

   S5 source path:

   - `get_rs_cache()` acquires `cache->lock`. [source](https://github.com/libunwind/libunwind/blob/v1.6.2/src/dwarf/Gparser.c#L595-L618)
   - `find_reg_state()` calls `fetch_proc_info()` on cache miss. [source](https://github.com/libunwind/libunwind/blob/v1.6.2/src/dwarf/Gparser.c#L908-L925)
   - `put_rs_cache()` releases `cache->lock` later, after `fetch_proc_info()`. [source](https://github.com/libunwind/libunwind/blob/v1.6.2/src/dwarf/Gparser.c#L946-L956)
   - `fetch_proc_info()` calls `tdep_find_proc_info()`. [source](https://github.com/libunwind/libunwind/blob/v1.6.2/src/dwarf/Gparser.c#L453-L462)
   - x86_64 local `tdep_find_proc_info()` maps to `dwarf_find_proc_info()`. [source](https://github.com/libunwind/libunwind/blob/v1.6.2/include/tdep-x86_64/libunwind_i.h#L250-L253)
   - `dwarf_find_proc_info()` calls `dl_iterate_phdr()`. [source](https://github.com/libunwind/libunwind/blob/v1.6.2/src/dwarf/Gfind_proc_info-lsb.c#L806-L808)
   - libunwind's wrapper calls libc `dl_iterate_phdr()`. [source](https://github.com/libunwind/libunwind/blob/v1.6.2/src/dl-iterate-phdr.c#L57-L64)
   - glibc `dl_iterate_phdr()` takes and later releases the loader lock. [source](https://github.com/bminor/glibc/blob/master/elf/dl-iteratephdr.c#L38-L81)
6. `S6`: `main` signals `t1` and waits until `t1` enters its signal handler.
7. `S7`: `t1` calls `unw_backtrace()` from the signal handler and blocks on the
   libunwind cache lock held by `t2`.
8. `S8`: `main` releases the outer callback flag, but `t1` cannot return to the
   callback to release the loader lock because it is stuck in the signal
   handler.
9. `S9`: none of the blocked paths returns, so the reproducer reports the
   deadlock.

The deadlock cycle is:

```text
thread/path          holds                    waits for
----------------------------------------------------------------------
t1 outer callback   glibc loader lock        t1 signal handler return
t2 signal handler   libunwind cache lock     glibc loader lock
t1 signal handler   nothing                  libunwind cache lock
```

The important point is that `main` does release `t1`'s callback flag. The
callback still cannot return, because the same `t1` thread is interrupted in
its signal handler and that handler is blocked inside libunwind.

## Source Pointers

The glibc side is `__dl_iterate_phdr`, which takes
`GL(dl_load_write_lock)` before invoking callbacks and releases it after the
callback loop. [source](https://github.com/bminor/glibc/blob/master/elf/dl-iteratephdr.c)

For libunwind 1.6.2 on x86_64, the continuous `unw_backtrace` to
`dl_iterate_phdr` path is:

- `unw_backtrace()`. [source](https://github.com/libunwind/libunwind/blob/v1.6.2/src/mi/backtrace.c#L57-L69)
- `tdep_trace()`. [source](https://github.com/libunwind/libunwind/blob/v1.6.2/src/x86_64/Gtrace.c#L398-L449)
- `trace_lookup()`. [source](https://github.com/libunwind/libunwind/blob/v1.6.2/src/x86_64/Gtrace.c#L273-L331)
- `trace_init_addr()`. [source](https://github.com/libunwind/libunwind/blob/v1.6.2/src/x86_64/Gtrace.c#L211-L249)
- `unw_step()`. [source](https://github.com/libunwind/libunwind/blob/v1.6.2/src/x86_64/Gstep.c#L56-L75)
- `dwarf_step()`. [source](https://github.com/libunwind/libunwind/blob/v1.6.2/src/dwarf/Gparser.c#L967-L972)
- `find_reg_state()`. [source](https://github.com/libunwind/libunwind/blob/v1.6.2/src/dwarf/Gparser.c#L908-L925)
- `fetch_proc_info()`. [source](https://github.com/libunwind/libunwind/blob/v1.6.2/src/dwarf/Gparser.c#L423-L461)
- `tdep_find_proc_info()` macro. [source](https://github.com/libunwind/libunwind/blob/v1.6.2/include/tdep-x86_64/libunwind_i.h#L250-L253)
- `dwarf_find_proc_info()`. [source](https://github.com/libunwind/libunwind/blob/v1.6.2/src/dwarf/Gfind_proc_info-lsb.c#L789-L808)
- `dl_iterate_phdr()`. [source](https://github.com/libunwind/libunwind/blob/v1.6.2/src/dl-iterate-phdr.c#L47-L64)
