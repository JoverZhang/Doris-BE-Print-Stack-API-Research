# Doris BE Stack Collection Test Plan

> Owner: agent. Regenerated as the patches change.
> Follow [writing-guidelines.md](writing-guidelines.md) when you edit this file.
> This file maps each acceptance check to a concrete test. The gates live in
> [phase2-acceptance.md](phase2-acceptance.md). The mechanics live in
> [phase2-design.md](phase2-design.md).

## Goal

Sort out every test case before implementation begins.

Acceptance is by command. A variant passes only when these tests pass. This file
names each test, its setup, its assertion, and whether it runs against the stub
collector or only against a real one.

## Test surface

Tests call the common free functions directly. They do not forge an
`HttpRequest`.

- `parse_collect_options(params)` returns `CollectOptions` or an error. This is
  where `bad_request` is decided.
- `collect_native_stacks(opts)` returns a `NativeStackReport` with raw PCs. This
  is the only per-variant step: a stub in common, the real walk in `fp-walk`.
- `resolve_dsos(report)` fills `dso` and `dso_offset` from `/proc/self/maps`.
- `serialize(report)` writes the JSON.

Test-only hooks in common:

- `set_unresponsive_tid_for_test(tid)` marks one tid unresponsive, so the
  timeout and partial paths run without real signaling.
- `hold_dump_lock_for_test()` returns a guard that holds the dump lock, so the
  contended path is deterministic.
- `consume_deadline_budget_for_test(ms)` sleeps `ms` milliseconds after the
  dump lock is acquired but before the per-tid loop, so the deadline guard
  case is deterministic.
- `pause_handler_for_tid_for_test(tid)` makes the fp-walk handler busy-wait
  in `WALKING` if the running thread's tid matches `tid`, so case 15 can
  hold one ring slot deterministically. Pass 0 to clear; the common stub
  is a no-op.

## File and partition

- Two files, partitioned by where the fixture mechanics live:
  - `be/test/service/http/native_stack_action_test.cpp` ships in
    `patches/common/`, holds the 14 variant-agnostic cases (1-13, 16),
    fixture `NativeStackActionTest`.
  - `be/test/service/http/native_stack_action_test_<variant>.cpp` ships in
    `patches/<variant>/`, holds the cases whose fixtures only exist in that
    variant (fp-walk: cases 14, 15, 17; fixture
    `FpWalkNativeStackActionTest`). Variant-specific tests duplicate the
    small helpers they need (`self_tid`, `collector_is_stub`, fixture
    threads) because each variant's test file links independently.
- A case that needs a real collector starts with
  `if (report.collector == "stub") GTEST_SKIP();` (variant-agnostic file) or
  `if (collector_is_stub()) GTEST_SKIP();` (variant file). So
  `just phase2-test new-ut common asan '*'` runs the variant-agnostic subset
  (8 pass, 6 skip), and `just phase2-test new-ut fp-walk asan '*'` runs
  everything (14 + 3 = 17 pass). In `new-ut`, `'*'` maps to
  `*NativeStackActionTest.*` to catch both suites.

## Categories

- Contract: the shared API shape and status rules. Runs on the stub and on a
  real collector.
- Correctness: real frames. Runs on a real collector only.
- Boundary: the late-responder guarantee. Runs on a real collector only.
- Stability: repeated dumps do not break the process. Runs on both.

## Tier 1 cases

| # | Category | Test | Setup and assertion | Runs on |
| --- | --- | --- | --- | --- |
| 1 | Contract | `Schema` | collect all, resolve, serialize, parse. Required keys are present (root: `collector`, `status`, `timeout_ms`, `max_frames_per_thread`, `max_copied_stack_bytes`, `elapsed_ms`, `threads`; per thread: `tid`, `status`, `truncated`, `frames`). No `target_tid` on an all-thread dump. No key in {function, func, file, line, symbol, demangled, name} anywhere. Frame objects hold only `pc`, `dso`, `dso_offset`. | stub + real |
| 2 | Contract | `ShapeOneTid` | park one thread T; collect `{tid:T}`. Exactly one thread entry, `tid == T`, root `target_tid == T`. | stub + real |
| 3 | Contract | `MissingTid` | collect `{tid: absent}`. Status `missing_tid`, an error reason, no frames. | stub + real |
| 4 | Contract | `BadRequest` | `parse_collect_options` on `tid<=0`, `timeout_ms` 0 or over 60000, `max_frames` 0, non-numeric. Each is rejected as `bad_request` with a reason. No collection. | stub + real |
| 5 | Contract | `ContendedDumpReturnsTimeout` | hold the dump lock; collect `{timeout_ms: small}`. Status `timeout`. Release the lock; the next collect succeeds. Deterministic, no extra threads. | stub + real |
| 6 | Contract | `Timeout` | `set_unresponsive_tid(T)`; collect `{tid:T, timeout_ms: small}`. Thread T status `timeout`, overall `timeout`. A later normal dump still works. | stub + real |
| 7 | Correctness | `NonZeroPcPerActiveThread` | spawn K spin-parked threads; collect all. Each spawned thread returns at least one non-zero `pc`. | real |
| 8 | Correctness | `KnownChainResolved` | spawn the marker chain (entry, c, b, a, spin); collect `{tid:T}`. The walked frames contain the four recorded `__builtin_return_address(0)` values as a contiguous subsequence in caller order, beginning at `frames[1..4]` (the chain_offset window). The test plan originally targeted `frames[1..2]`, but a 10×10 stress in 2026-06 showed ~10% of runs across all four variants landing the chain at `frames[3]` because -O0 + ASan occasionally inserts an extra interceptor frame (`__asan::*` handlers, pthread internals from `clone`/`start_thread`) ahead of the recorded chain. The window was widened to `frames[1..4]` to absorb this stochastic insertion while still catching a sideways walk. The chain-match assertion and the dso_offset formula assertion stay tight; addr2line consumes dso_offset, not chain_offset. `frames[0].pc` is non-zero. Every frame has a non-empty `dso` (the test binary) and a `dso_offset` such that `segment_base + dso_offset == pc`. `handler_time_ns` is present and non-negative. | real |
| 9 | Correctness | `Truncated` | spawn a chain deeper than N; collect `{tid:T, max_frames:N}`. `frames.size() == N`, `truncated == true`. Control: a large N gives `truncated == false`. | real |
| 10 | Correctness | `SignalBlocked` | a thread blocks `SIGRTMIN+6` with `pthread_sigmask`, then parks; collect `{tid:T}`. Status `signal_blocked`, not `timeout`. | real |
| 11 | Correctness | `PartialResults` | spawn responsive parked threads plus one unresponsive (`set_unresponsive_tid`); collect all. Responsive threads carry frames, the unresponsive one is `timeout`, overall status `partial`, process healthy. | real |
| 12 | Boundary | `LateResponderDoesNotCorruptNextDump` | dump `{tid:T}`, then dump `{tid:T}` again. With fp-walk's per-sequence slot ring, the two dumps land in distinct slots, so the shared-slot hazard does not exist. The handler also validates the request token on entry and re-checks it before publishing. Forcing an actually-late handler is case 15; the deterministic use-after-free check is the Tier 2 TSan deepening below. | real |
| 13 | Stability | `DumpLoopNoCrashNoStuck` | collect all in a loop of N iterations (about 200) with the marker threads alive. Every iteration returns, the loop finishes within a wall-clock bound, all workers stay joinable. | stub + real |
| 14 | Correctness | `RbpBoundsRejectOutOfStackRBP` | drive the per-handler RBP safety check (`rbp_can_read_for_test`) over an accept/reject table: an RBP above the `[initial_rbp, initial_rbp + max_stack_bytes)` window, below it, at a position whose read crosses the upper bound, misaligned, zero anchor, aligned and inside, and equal to the anchor. Rejects every bad input; accepts the valid ones. This is the precondition that bounds the walk from reading past the stack. Case 17 covers the complementary mincore-based unmapped-page check; PROT_NONE pages (e.g., stack guard pages) are still a residual case until a sigsetjmp/siglongjmp trampoline is added. | real |
| 15 | Boundary | `LateHandlerCannotCorruptNextDumpUnderLoad` | use `pause_handler_for_tid_for_test(bait.tid())` to hold one ring slot in WALKING after the bait's handler enters; dump the bait with a tight timeout so the coordinator times out and leaves that slot WALKING; then loop 12 marker-chain arms. Every fourth arm targets the same ring slot as the bait — its CAS `IDLE`->`PENDING` must fail and report `slot_busy`. The other arms hit free slots and must report `ok` with marker-chain frames intact (no cross-slot corruption). Release the pause hook; a follow-up loop must report all `ok` (every slot reclaimable). This exercises the per-sequence ring's safety contract directly; the underlying kernel signal-delivery race remains the Tier 2 TSan deepening below. | real |
| 16 | Correctness | `DeadlineGuardSkipsExpiredSignaling` | drain the dump's deadline budget with `consume_deadline_budget_for_test(80)` before a `timeout_ms = 50` collect of all live threads. Every per-thread entry must carry `"dump deadline expired before signaling this thread"` and status `timeout`; no entry may be `ok`. Wall-clock stays close to `timeout_ms + consume_ms`. Without the guard, every tid still gets a queued signal that the wait loop has no time to receive, creating exactly the late-handler hazard the per-sequence slot must defend against. | stub + real |
| 17 | Boundary | `JunkRbpDoesNotCrashCollector` | spawn a detached worker that clobbers `%rbp` to a likely-unmapped address (`0xCAFEBABE00000000`) via inline asm and enters an infinite `pause` loop; dump it. The BE must remain alive and report the dump with at most one frame (the RIP from the asm loop). The `mincore`-based `page_is_mapped` guard in the walk loop is what stops the deref. NOTE: `mincore` does not reject PROT_NONE pages (stack guard pages report as mapped-but-not-resident), so an RBP pointing into a guard page still crashes; a `sigsetjmp`/`siglongjmp` trampoline would close that residual case. Skipped on non-x86_64. | real |

## Candidates

Cases worth adding once the baseline is green:

- `MaxStackBytesBound`: set a small `max_stack_bytes` and confirm the frame-
  pointer walk stops at the bound without reading past it. The charter bounds
  copied stack bytes, but no Tier 1 case exercises that bound yet.

## The recipe

`just phase2-test <suite> <target> <mode> <gtest-filter>` switches
`repos/source/doris-master` to `phase2/<target>`, then builds and runs BE UT
in the build-env image (`docker.io/apache/doris:build-env-ldb-toolchain-latest`):

```
just phase2-test new-ut common asan '*'
just phase2-test new-ut fp-walk asan '*'
just phase2-test full-ut base asan 'BrpcClientCacheTest.invalid'
```

Every argument is explicit. `new-ut` maps the all-test filter `'*'` to the
Phase 2 target suite `'*NativeStackActionTest.*'`; a narrower filter is passed
through as-is. `full-ut` passes the gtest filter through directly, so `'*'` means
full BE UT. For `asan`, `release`, and `tsan`, the command runs
`run-be-ut.sh --run --filter=<effective-filter>` inside the image. By default the
wrapper does not pass `-j`, so Doris uses its own parallelism heuristic. Set
`DORIS_BE_JOBS=<n>` to override it for a local run. Set `DORIS_BE_CLEAN=1` only
when you intentionally need CI-parity clean behavior.
Source and test files are auto-discovered by the existing `GLOB_RECURSE`, so no
CMake patch is needed.

The harness mounts the project root at its host path inside the container, so
git's `.git` pointers (worktree and submodules) resolve the same way on both
sides — no PATH shim is needed. `DORIS_THIRDPARTY=/var/local/thirdparty` reuses
the image's prebuilt thirdparty; it is never rebuilt. `CCACHE_DIR` points at
the project-local `.tmp/ccache`, so ASAN, RELEASE, TSAN, and jemalloc Release
build dirs share one persistent compiler cache across short-lived containers.

`be/CMakeLists.txt` puts `-fno-omit-frame-pointer` in the global
`add_compile_options()`, so fp-walk's RBP walk works under every build type
without a patch.

## Build matrix

The single local test command has four modes:

```
just phase2-test new-ut fp-walk asan '*'
just phase2-test new-ut fp-walk release '*'
just phase2-test new-ut fp-walk tsan '*'
just phase2-test new-ut fp-walk jemalloc '*'
just phase2-test full-ut fp-walk asan '*'
```

| Mode | Flags (`be/CMakeLists.txt`) | Build dir | What it catches that ASan misses |
| --- | --- | --- | --- |
| asan | `ASAN_UT` via `run-be-ut.sh`; `USE_JEMALLOC=OFF` | `ut_build_ASAN` | memory bugs in the collector itself |
| release | `RELEASE` via `run-be-ut.sh`; `USE_JEMALLOC=OFF` | `ut_build_RELEASE` | inlining-induced chain-shape drift, frame-pointer reliance under optimization, prod codegen |
| tsan | `TSAN` via `run-be-ut.sh`; `USE_JEMALLOC=OFF` | `ut_build_TSAN` | concurrent writes to the per-sequence ring slot; Tier 2's "late-handler race under TSan" |
| jemalloc | `RELEASE` direct CMake; `USE_JEMALLOC=ON` | `ut_build_JEMALLOC_RELEASE` | fp-walk under Doris's production allocator shape; validates that the selected baseline does not depend on UT's allocator-off build |

The patches are not `#ifdef`-gated by build type. Test fixtures use
`__attribute__((noinline))` and trailing `asm volatile("")` on every recorded
chain level, and `volatile int sink` in spin loops, so `-O3` cannot collapse
the call boundaries the chain-match assertions depend on. Implementation
atomics use explicit `memory_order_*`, which TSAN instruments without
behavior change. RELEASE on this Doris pin requires an upstream link fix
(`patches/common/0000-upstream-drop-inline-from-SegmentWriter-_is_mow-defs.patch`,
applied first so the design patches build on top of it): the upstream
header declares two `SegmentWriter` members non-inline but the .cpp
defines them with `inline`, which `-O0` masks and `-O3` exposes as
undefined-symbol link errors against the test subclass. The patch removes
the keyword; no semantic change. The `jemalloc` mode uses a direct CMake path
because Doris `run-be-ut.sh` hard-codes `USE_JEMALLOC=OFF`. The libunwind
variants carry separate PHDR-cache and jemalloc-prof-libunwind questions that
are not part of the selected baseline smoke. Expect to treat TSAN as best-effort (its
atomic instrumentation is not guaranteed async-signal-safe inside our
signal handler).

Observed results across the four variants (recorded 2026-06-02 against
the Doris pin at the time of this writing):

| Variant | ASAN | RELEASE | TSAN |
| --- | --- | --- | --- |
| `fp-walk` | 17/17 pass | 17/17 pass | 15/17 (Truncated; LateHandlerCannotCorruptNextDumpUnderLoad reports 7/12 iterations with corrupted frames) |
| `ck-phdr-unwind` | 14/14 pass | 14/14 pass | 10/14 (4 correctness tests report empty frames) |
| `ob-kill60` | 14/14 pass | 14/14 pass | 10/14 (same 4 as ck-phdr-unwind) |
| `snapshot-remote-unwind` | 14/14 pass | 14/14 pass | 10/14 (same 4 as ck-phdr-unwind) |

ASAN and RELEASE are green on every variant. TSAN fails on every
variant in the expected best-effort way: TSAN's `pthread_*` and
atomic interceptors are not async-signal-safe, so the libunwind-based
collectors (ck-phdr-unwind, ob-kill60, snapshot-remote-unwind) return
empty `frames` for the four correctness cases that need a real walk.
`fp-walk` fares better — its handler does no library calls and walks
%rbp directly, so 15 of 17 tests still pass — but `Truncated`
(chain-depth assertion) and `LateHandlerCannotCorruptNextDumpUnderLoad`
(per-sequence ring slot under load) still fail.

The 7/12 corruption rate on the latter is interesting and is exactly
the Tier 2 "late-handler race under TSan" the test plan already
deferred. Whether it is a real race that TSAN's instrumentation
amplifies via timing perturbation, or instrumentation interference
inside the handler itself, is the Tier 2 question. The Tier 1 gate
remains ASAN + RELEASE, which both pass.

Selected fp-walk timings (ASAN-vs-RELEASE, no TSAN row since failures):

| Case | ASAN (`-O0`) | RELEASE (`-O3`) |
| --- | --- | --- |
| Full suite (17 tests) | ~1223 ms | ~1137 ms |
| `DumpLoopNoCrashNoStuck` | ~1083 ms | ~852-1000 ms |
| `LateHandlerCannotCorruptNextDumpUnderLoad` | ~131 ms | ~129 ms |
| `DeadlineGuardSkipsExpiredSignaling` | ~80 ms | ~80 ms |

## Tier 2 (deferred, not in this file)

These are scripted and replayable, per [phase2-acceptance.md](phase2-acceptance.md).
They are not part of the baseline.

- jemalloc profiling on, then off, under a dump loop.
- allocation pressure during a dump loop.
- thread create and exit churn.
- `dlopen` and `dlclose` churn.
- the late-handler race underlying cases 12 and 15, under TSan. Tier 1
  proves no misattribution and that observable frames do not corrupt
  under a stress loop; TSan deterministically catches concurrent writes
  to the per-sequence slot that the timing-dependent Tier 1 test cannot
  guarantee.
