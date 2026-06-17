# Debugging

Use these commands after building the matrix:

```bash
./build.sh
```

## Capture The Deadlock Stack

Run this from `reproduce/pr22549-jemalloc-minimal`:

```bash
mkdir -p .tmp/debug-prev-prof-on && \
env \
  JEMALLOC_CONF='prof:true,prof_active:true,lg_prof_interval:20,prof_prefix:.tmp/debug-prev-prof-on/jemalloc_heap_profile' \
  MALLOC_CONF='prof:true,prof_active:true,lg_prof_interval:20,prof_prefix:.tmp/debug-prev-prof-on/jemalloc_heap_profile' \
  timeout -s INT 8s gdb -q -batch \
    -ex 'set debuginfod enabled off' \
    -ex 'set pagination off' \
    -ex 'set filename-display absolute' \
    -ex 'run' \
    -ex 'thread apply all bt' \
    -ex 'quit' \
    --args .tmp/bin/prev/jemalloc_dl_iterate_phdr_reproducer
```

The expected result is exit code `124` from `timeout`. The gdb output should
show this shape:

```text
malloc_init_hard
jecalloc / doris_calloc
_dlerror_run
dlsym / getOriginalDLIteratePHDR
dl_iterate_phdr
_Unwind_Backtrace
je_prof_boot2
malloc_init_hard
trigger_jemalloc_before_main
```

This is the parent glibc commit:

```text
b2964eb1d9a6b8ab1250e8a881cf406182da5875
```

## Fixed Commit Control

The fixed glibc commit should return to `main` instead of timing out:

```bash
mkdir -p .tmp/debug-fixed-prof-on && \
env \
  JEMALLOC_CONF='prof:true,prof_active:true,lg_prof_interval:20,prof_prefix:.tmp/debug-fixed-prof-on/jemalloc_heap_profile' \
  MALLOC_CONF='prof:true,prof_active:true,lg_prof_interval:20,prof_prefix:.tmp/debug-fixed-prof-on/jemalloc_heap_profile' \
  gdb -q -batch \
    -ex 'set debuginfod enabled off' \
    -ex 'set pagination off' \
    -ex 'set filename-display absolute' \
    -ex 'run' \
    -ex 'thread apply all bt' \
    -ex 'quit' \
    --args .tmp/bin/fixed/jemalloc_dl_iterate_phdr_reproducer
```

The expected output contains:

```text
shim: _Unwind_Backtrace entered
shim: _Unwind_Backtrace returned
constructor: malloc returned
main: reached
```

This is the fixed glibc commit:

```text
fada9018199c21c469ff0e731ef75c6020074ac9
```
