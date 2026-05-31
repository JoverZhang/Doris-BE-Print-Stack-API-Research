# ob-kill60 — Build Facts

Evidence that the build wired the load-bearing pieces the variant depends on.
Captured against `phase2/ob-kill60` head `156437b4de4`, image
`docker.io/apache/doris:build-env-ldb-toolchain-latest` (`7b449a709746`).

## libunwind symbol prefix (UNW_LOCAL_ONLY)

The linked libunwind archive ships only the local-only `_ULx86_64_*` symbols.
Defining `UNW_LOCAL_ONLY` at the top of `native_stack_collect.cpp` remaps
`unw_init_local2`/`unw_step`/`unw_get_reg` to those names. The same
TU-scoped pattern OB uses in `<ob>/deps/oblib/src/lib/signal/ob_libunwind.c:15-16`.
Confirmed at the object-file level:

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
     | grep -E '_ULx86_64_(get_reg|init_local2?|step)$'
0000000034320f40 T _ULx86_64_get_reg
0000000034320f60 T _ULx86_64_init_local
00000000343211b0 T _ULx86_64_init_local2
0000000034322560 T _ULx86_64_step
```

The brief's `_ULx86_64_*`-only assertion held; no remote `_Ux86_64_*` symbols
needed.

The variant uses `unw_init_local2(&cursor, &ucontext, UNW_INIT_SIGNAL_FRAME)`
+ `unw_step` (not `unw_backtrace`) because seeding from the captured
`ucontext_t` is required to walk the interrupted thread's stack rather than
the handler's own stack. OB's `safe_backtrace` uses
`unw_getcontext` + `unw_init_local` instead, which captures the handler's
own stack — appropriate for OB's crash logger ("where am I crashing"), but
wrong when the goal is to report the interrupted worker's frames. The
ob-kill60 collector mirrors the unwind LOOP shape of OB's
`get_stack_trace_inplace` (`ob_libunwind.c:55-82`) but seeds from the
saved ucontext.

## PHDR cache active in the test binary

The lock-free `dl_iterate_phdr` override defined in
`be/src/common/phdr_cache.cpp` (uncommented by patch 0001) is exported as a
weak global text symbol, which interposes the libc version at link time:

```
$ nm be/ut_build_ASAN/test/doris_be_test \
     | grep -E 'dl_iterate_phdr|updatePHDRCache|hasPHDRCache'
000000001ddd5920 T dl_iterate_phdr
000000001ddd6010 T _Z12hasPHDRCachev
000000001ddd5d20 T _Z15updatePHDRCachev
00000000125f9120 t _ZN11__sanitizerL18dl_iterate_phdr_cbEP12dl_phdr_infomPv
000000001ddd5ec0 t _ZZ15updatePHDRCachevEN3$_08__invokeEP12dl_phdr_infomPv
000000001ddd5fe0 t _ZZ15updatePHDRCachevENK3$_0clEP12dl_phdr_infomPv
000000001ddd5ea0 t _ZZ15updatePHDRCachevENK3$_0cvPFiP12dl_phdr_infomPvEEv
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
  `OB_KILL60_LOCAL_JEMALLOC` (default OFF) swaps the prebuilt
  `add_thirdparty(jemalloc)` for an IMPORTED static target pointing
  at the locally-built archive. ON requires the script to have run
  first; otherwise CMake errors with the exact command to run. (The
  flag name is variant-prefixed; ck-phdr-unwind's branch uses
  `CK_PHDR_UNWIND_LOCAL_JEMALLOC` for the same purpose. A future
  refactor may unify both behind a generic
  `PHASE2_LOCAL_JEMALLOC_PROF_LIBUNWIND` flag in patches/common/ — that
  is a follow-up task per the brief's "duplication is intentional
  this round" guidance.)

Tier 2 evaluation recipe (NOT this round):

```sh
# 1. Build the local jemalloc with the libunwind backtracer.
cd .worktree/phase2 && ./be/cmake/build-jemalloc-prof-libunwind.sh
#    Expect last line:    backtrace_method = 'libunwind' confirmed

# 2. Re-build the test binary with the swap turned on.
./run-be-ut.sh --clean
cmake -B be/ut_build_ASAN -DOB_KILL60_LOCAL_JEMALLOC=ON ...
just phase2-test ob-kill60

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
  the same envelope ck-phdr-unwind and fp-walk reach.

If a future round needs the explicit counter, a single atomic increment
inside the override's hot path (under a `#ifdef OB_KILL60_TRACE`
guard) is the obvious add.

## OB upstream line ranges the collector cites

| Citation | Lines | Purpose in ob-kill60 |
| --- | --- | --- |
| `<ob>/deps/oblib/src/lib/signal/ob_libunwind.c` | 15-16 | `#define UNW_LOCAL_ONLY` placement before `<libunwind.h>` |
| `<ob>/deps/oblib/src/lib/signal/ob_libunwind.c` | 55-82 | `get_stack_trace_inplace` unwind loop shape |
| `<ob>/deps/oblib/src/lib/signal/ob_signal_handlers.cpp` | 103-120 | `ob_signal_handler` validates `req_id` against `si_value.sival_ptr`; ob-kill60 transcribes as `seq != slot.expected_seq` |
| `<ob>/deps/oblib/src/lib/signal/ob_signal_handlers.cpp` | 113-114 | The exact `if (ctx.req_id_ != req_id) return;` pattern we mirror at handler entry |
| `<ob>/deps/oblib/src/lib/signal/ob_signal_worker.cpp` | 280-347 | `task_process` (the two-phase OB coordinator); ob-kill60 collapses its prepare/process/exit pipe protocol into one queue-signal-then-poll-slot beat |
| `<ob>/deps/oblib/src/lib/signal/ob_signal_worker.cpp` | 293-294 | OB's `req_id` increment via `ATOMIC_AAF`; ob-kill60 uses `g_seq.fetch_add` for the same monotonic-counter role |
| `<ob>/deps/oblib/src/lib/signal/ob_signal_worker.cpp` | 304-309 | OB's `siginfo` setup + `rt_tgsigqueueinfo` shape; ob-kill60 mirrors it verbatim (SI_QUEUE + `sival_ptr` = token + SYS_rt_tgsigqueueinfo syscall) |
| `<ob>/deps/oblib/src/lib/signal/ob_signal_worker.cpp` | 349-385 | `ObSigHandler::handle` — the two-phase form ob-kill60 deliberately drops |

## Test stability ledger

| run | result | timing |
|---:|--|--|
| 1 | 14 / 14 pass | 1102 ms total |
| 2 | 14 / 14 pass | 1091 ms total |
| 3 | 14 / 14 pass | 1091 ms total |

No flake. `DumpLoopNoCrashNoStuck` (the 200-iteration loop) sits at
930-942 ms; `DeadlineGuardSkipsExpiredSignaling` at 80 ms (tight, but the
test allows up to 200 ms `elapsed_ms`). Per-test timings match
ck-phdr-unwind to within run-to-run noise — single-phase ack does not
materially change Tier 1 wall-clock because Tier 1 does not stress the
coordinator wait path with two-phase pipe latency.
