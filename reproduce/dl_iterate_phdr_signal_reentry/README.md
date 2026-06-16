# libunwind signal reentry deadlock reproducer

This directory contains one program that reproduces the signal-handler deadlock
around libunwind's `unw_backtrace()` path to glibc `dl_iterate_phdr()`.

Build:

```bash
cd ../../.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind
autoreconf -i
mkdir -p _build-local
cd _build-local
../configure --prefix="$PWD/_install"
make -j"$(nproc)"

cd ../../../../../../reproduce/dl_iterate_phdr_signal_reentry
bash build.sh
```

`build.sh` links the reproducer to the OceanBase vendored libunwind build at
`../../.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/_build-local/src/.libs`.

Run:

```bash
./libunwind_signal_deadlock_reproducer
```

Expected result:

```text
S9 result: libunwind signal reentry deadlock reproduced
```

The reproducer exits with `124` after it confirms the deadlock.

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

   - https://github.com/libunwind/libunwind/blob/v1.6.2/src/dwarf/Gparser.c#L595-L618 - `get_rs_cache()` acquires `cache->lock`.
   - https://github.com/libunwind/libunwind/blob/v1.6.2/src/dwarf/Gparser.c#L908-L925 - `find_reg_state()` calls `fetch_proc_info()` on cache miss.
   - https://github.com/libunwind/libunwind/blob/v1.6.2/src/dwarf/Gparser.c#L946-L956 - `put_rs_cache()` releases `cache->lock` later, after `fetch_proc_info()`.
   - https://github.com/libunwind/libunwind/blob/v1.6.2/src/dwarf/Gparser.c#L453-L462 - `fetch_proc_info()` calls `tdep_find_proc_info()`.
   - https://github.com/libunwind/libunwind/blob/v1.6.2/include/tdep-x86_64/libunwind_i.h#L250-L253 - x86_64 local `tdep_find_proc_info()` maps to `dwarf_find_proc_info()`.
   - https://github.com/libunwind/libunwind/blob/v1.6.2/src/dwarf/Gfind_proc_info-lsb.c#L806-L808 - `dwarf_find_proc_info()` calls `dl_iterate_phdr()`.
   - https://github.com/libunwind/libunwind/blob/v1.6.2/src/dl-iterate-phdr.c#L57-L64 - libunwind's wrapper calls libc `dl_iterate_phdr()`.
   - https://github.com/bminor/glibc/blob/master/elf/dl-iteratephdr.c#L38-L81 - glibc `dl_iterate_phdr()` takes and later releases the loader lock.
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

## Debugging

Set `HOLD_ON_DEADLOCK_SECONDS` to keep the reproducer alive after it detects a
deadlock:

```bash
HOLD_ON_DEADLOCK_SECONDS=20 ./libunwind_signal_deadlock_reproducer
```

For a gdb-launched stack capture:

```bash
gdb -batch -q ./libunwind_signal_deadlock_reproducer \
  -ex 'set pagination off' \
  -ex 'handle SIG34 nostop noprint pass' \
  -ex 'handle SIG35 nostop noprint pass' \
  -ex 'set env HOLD_ON_DEADLOCK_SECONDS 999' \
  -ex 'break hold_on_deadlock_if_requested' \
  -ex 'run' \
  -ex 'thread apply all bt' \
  -ex 'quit'
```

On the tested host, the relevant frames were:

```text
t2: unw_backtrace -> _ULx86_64_step -> ... -> dl_iterate_phdr -> pthread_mutex_lock
t1: signal handler -> unw_backtrace -> _ULx86_64_step -> pthread_mutex_lock
```

## Source Pointers

The glibc side is `__dl_iterate_phdr`, which takes
`GL(dl_load_write_lock)` before invoking callbacks and releases it after the
callback loop:

```text
https://github.com/bminor/glibc/blob/master/elf/dl-iteratephdr.c
```

For libunwind 1.6.2 on x86_64, the continuous `unw_backtrace` to
`dl_iterate_phdr` path is:

- https://github.com/libunwind/libunwind/blob/v1.6.2/src/mi/backtrace.c#L57-L69 - `unw_backtrace()`
- https://github.com/libunwind/libunwind/blob/v1.6.2/src/x86_64/Gtrace.c#L398-L449 - `tdep_trace()`
- https://github.com/libunwind/libunwind/blob/v1.6.2/src/x86_64/Gtrace.c#L273-L331 - `trace_lookup()`
- https://github.com/libunwind/libunwind/blob/v1.6.2/src/x86_64/Gtrace.c#L211-L249 - `trace_init_addr()`
- https://github.com/libunwind/libunwind/blob/v1.6.2/src/x86_64/Gstep.c#L56-L75 - `unw_step()`
- https://github.com/libunwind/libunwind/blob/v1.6.2/src/dwarf/Gparser.c#L967-L972 - `dwarf_step()`
- https://github.com/libunwind/libunwind/blob/v1.6.2/src/dwarf/Gparser.c#L908-L925 - `find_reg_state()`
- https://github.com/libunwind/libunwind/blob/v1.6.2/src/dwarf/Gparser.c#L423-L461 - `fetch_proc_info()`
- https://github.com/libunwind/libunwind/blob/v1.6.2/include/tdep-x86_64/libunwind_i.h#L250-L253 - `tdep_find_proc_info()` macro
- https://github.com/libunwind/libunwind/blob/v1.6.2/src/dwarf/Gfind_proc_info-lsb.c#L789-L808 - `dwarf_find_proc_info()`
- https://github.com/libunwind/libunwind/blob/v1.6.2/src/dl-iterate-phdr.c#L47-L64 - `dl_iterate_phdr()`
