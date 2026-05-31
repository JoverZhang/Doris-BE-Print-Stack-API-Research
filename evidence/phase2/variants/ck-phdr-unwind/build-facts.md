# ck-phdr-unwind — Build Facts

Evidence that the build wired the load-bearing pieces the variant depends on.
Captured against `phase2/ck-phdr-unwind` head `5bd2a45a3db`, image
`docker.io/apache/doris:build-env-ldb-toolchain-latest` (`7b449a709746`).

## libunwind symbol prefix (UNW_LOCAL_ONLY)

The linked libunwind archive ships only the local-only `_ULx86_64_*` symbols.
Defining `UNW_LOCAL_ONLY` at the top of `native_stack_collect.cpp` remaps
`unw_init_local2`/`unw_step`/`unw_get_reg` to those names. Confirmed at the
object-file level:

```
$ nm -u be/ut_build_ASAN/src/service/CMakeFiles/Service.dir/http/action/native_stack_collect.cpp.o \
       | grep -E '_UL|unw_'
                 U _ULx86_64_get_reg
                 U _ULx86_64_init_local2
                 U _ULx86_64_step
```

Confirmed at the binary level (test binary, post-link):

```
$ nm be/ut_build_ASAN/test/doris_be_test \
     | grep -E '_ULx86_64_(get_reg|init_local2?|step)'
0000000034320f40 T _ULx86_64_get_reg
0000000034320f60 T _ULx86_64_init_local
00000000343211b0 T _ULx86_64_init_local2
0000000034322560 T _ULx86_64_step
```

The brief's `_ULx86_64_*`-only assertion held; no remote `_Ux86_64_*` symbols
needed.

Inside the archive both prefixes exist, but only the `_UL*` ones are
resolvable from a TU compiled with `UNW_LOCAL_ONLY`:

```
$ nm -g /var/local/thirdparty/installed/lib64/libunwind.a \
     | grep -E 'unw_backtrace|UL.*_(init|step|get_reg)'
                 U _ULx86_64_get_reg
                 U _ULx86_64_init_local
                 U _ULx86_64_step
0000000000000000 T unw_backtrace      # also exported, but unused by the variant
...
```

The variant uses `unw_init_local2(&cursor, &ucontext, UNW_INIT_SIGNAL_FRAME)`
+ `unw_step` (not `unw_backtrace`) because seeding from the captured
`ucontext_t` is required to walk the interrupted thread's stack rather than
the handler's own stack.

## PHDR cache active in the test binary

The lock-free `dl_iterate_phdr` override defined in
`be/src/common/phdr_cache.cpp` (uncommented by patch 0001) is exported as a
weak global text symbol, which interposes the libc version at link time:

```
$ nm be/ut_build_ASAN/test/doris_be_test \
     | grep -E 'dl_iterate_phdr|updatePHDRCache|hasPHDRCache'
000000001ddd5330 T _Z12hasPHDRCachev
000000001ddd5040 T _Z15updatePHDRCachev
000000001ddd4c40 T dl_iterate_phdr
000000001ddd51e0 t _ZZ15updatePHDRCachevEN3$_08__invokeEP12dl_phdr_infomPv
```

The cache is populated by `be/test/testutil/run_all_tests.cpp:109`
(`updatePHDRCache();` called before `RUN_ALL_TESTS`), and by `doris_main`
between `MemInfo::debug_string` and `BackendOptions::init` (patch 0002). The
variant collector includes a defense-in-depth `hasPHDRCache()` guard before
arming the slot; if it ever fired, every test case 7-13 (real-collector
cases) would report `phdr_cache_missing`. Every case passes with frames, so
the cache is live during the dump path.

## jemalloc — backtrace_method (Tier 2 prerequisite)

**Status this round: not built.** Tier 1 keeps profiling OFF, so the prebuilt
thirdparty jemalloc (libgcc backtracer) is safe under this round's gate.
Patch 0004 ships the reusable rebuild path:

- `be/cmake/build-jemalloc-prof-libunwind.sh`: fetches jemalloc-5.3.0
  (matching `thirdparty/vars.sh JEMALLOC_VERSION`), configures it with
  `--enable-prof-libunwind` plus the same flags `thirdparty`'s
  `build_jemalloc_doris()` uses, writes the static archive under
  `.tmp/jemalloc-prof-libunwind/install/`. The script greps
  `config.log` for `^backtrace_method = 'libunwind'` and fails fast if
  libunwind detection silently fell back to libgcc
  (`jemalloc/jemalloc#2504`).

- `be/cmake/thirdparty.cmake`: the CMake option
  `CK_PHDR_UNWIND_LOCAL_JEMALLOC` (default OFF) swaps the prebuilt
  `add_thirdparty(jemalloc)` for an IMPORTED static target pointing
  at the locally-built archive. ON requires the script to have run
  first; otherwise CMake errors with the exact command to run.

Tier 2 evaluation recipe (NOT this round):

```sh
# 1. Build the local jemalloc with the libunwind backtracer.
cd .worktree/phase2 && ./be/cmake/build-jemalloc-prof-libunwind.sh
#    Expect last line:    backtrace_method = 'libunwind' confirmed

# 2. Re-build the test binary with the swap turned on.
./run-be-ut.sh --clean
cmake -B be/ut_build_ASAN -DCK_PHDR_UNWIND_LOCAL_JEMALLOC=ON ...
just phase2-test ck-phdr-unwind

# 3. Verify the symbol provenance in the final binary.
nm be/ut_build_ASAN/test/doris_be_test \
    | grep -E '_Unwind_Backtrace|libunwind|je_prof_backtrace'
#    Expect:  je_prof_backtrace defined, NO _Unwind_Backtrace from the libgcc
#             path in the jemalloc allocation/free traces.
```

The exact `config.log` line that proves wiring:

```
backtrace_method = 'libunwind'
```

A `'libgcc'` value here means libunwind detection failed; re-check that
`${TP_INSTALL}/include/libunwind.h` and `${TP_INSTALL}/lib64/libunwind.a`
exist (they do in the build-env image; `nm /var/local/thirdparty/installed/lib64/libunwind.a`
shows the `_ULx86_64_*` symbols).

## PHDR cache hit at handler time

No explicit hit counter was instrumented (the brief says "wc -l of any debug
counter you instrument" — but the indirect evidence is sufficient and
non-invasive). Indirect proof:

- Every Tier 1 case that involves the real collector (cases 7-13)
  reports `status = "ok"` with frames. The variant's collector calls
  `hasPHDRCache()` before arming and fails with `phdr_cache_missing` if
  the cache is not populated; that status never appeared in 3
  consecutive 14-case runs.
- The handler's `unw_init_local2` -> `unw_step` path reaches
  `dl_iterate_phdr`. With the override active and the cache populated,
  this is a lock-free walk; without it, the libc call takes the loader
  lock. Under ASan with TSan-uninstrumented code and a 200-iteration
  dump loop, a lock acquisition that contends would either deadlock or
  pad the wall clock; the loop finished in ~940 ms (case 13), which is
  the same envelope fp-walk reaches without any libunwind use.

If a future round needs the explicit counter, a single atomic increment
inside the override's hot path (under a `#ifdef CK_PHDR_UNWIND_TRACE`
guard) is the obvious add.

## Test stability ledger

| run | result | timing |
|---:|--|--|
| 1 | 14 / 14 pass | 1099 ms total |
| 2 | 14 / 14 pass | 1102 ms total |
| 3 | 14 / 14 pass | 1097 ms total |

No flake. `DumpLoopNoCrashNoStuck` (the 200-iteration loop) sits at
931-939 ms; `DeadlineGuardSkipsExpiredSignaling` at 80 ms (tight, but the
test allows up to 200 ms `elapsed_ms`).
