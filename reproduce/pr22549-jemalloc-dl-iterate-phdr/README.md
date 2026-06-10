# PR 22549 jemalloc dl_iterate_phdr reproducer

This is a focused reproducer for the pre-`main()` hang caused by enabling the
old Doris `dl_iterate_phdr` override while jemalloc heap profiling is active.

Run from the project root:

```bash
./reproduce/pr22549-jemalloc-dl-iterate-phdr/run.sh
```

Defaults:

- `DORIS_BE_JOBS=31`
- `REPRO_TIMEOUT=8`

The script runs inside the Doris build container. It temporarily stashes dirty
changes in `repos/source/doris-master`, switches to `DORIS_BASE`, applies
`repro.patch`, rebuilds the affected BE objects and relinks `doris_be`, then
runs gdb with a breakpoint on `main`.

The first profiling case uses the stock container jemalloc archive. The
expected result is that `main` is not reached; gdb is interrupted by timeout
and the captured stack contains `getOriginalDLIteratePHDR`, `dl_iterate_phdr`,
`_Unwind_Backtrace`, `je_prof_boot2`, and nested `malloc_init_hard`.

The second profiling case applies the existing `ck-phdr-unwind` thirdparty
patch, reuses `scripts/phase2/phase2-jemalloc.sh` to sync or build the
phase2 jemalloc prof-libunwind cache, relinks `doris_be`, and asserts that the
same profiling configuration reaches `main`.

The stable committed result is `expected-key-frames.txt`, a normalized excerpt
of the gdb stack with run-specific addresses and LWP ids replaced by
placeholders. The raw `gdb-stack.txt` and the prof-libunwind control
`libunwind-prof-main.txt` remain under `.tmp/latest/` for inspection.

Artifacts are written under:

```text
reproduce/pr22549-jemalloc-dl-iterate-phdr/.tmp/latest/
```

`just phase2-reset` removes the `.tmp` directory.
