# Debugging

Use these commands after building the reproducer with [BUILD.md](BUILD.md).

## Keep the Process Alive

Set `HOLD_ON_DEADLOCK_SECONDS` to keep the reproducer alive after it detects a
deadlock:

```bash
HOLD_ON_DEADLOCK_SECONDS=20 ./libunwind_signal_deadlock_reproducer
```

## Capture Stacks with gdb

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
