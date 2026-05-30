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
  `just phase2-test common` runs the variant-agnostic subset (8 pass, 6
  skip), and `just phase2-test fp-walk` runs everything (14 + 3 = 17 pass).
  The harness filter is `*NativeStackActionTest.*` to catch both suites.

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
| 8 | Correctness | `KnownChainResolved` | spawn the marker chain (entry, c, b, a, spin); collect `{tid:T}`. The walked frames contain the four recorded `__builtin_return_address(0)` values as a contiguous subsequence in caller order, beginning at `frames[1]` or `frames[2]` — the test plan targets `frames[1..4]`, and -O0 + ASan sometimes interposes one extra frame between the RIP and the recorded chain (this is the walk-quality margin Gate B will tighten). `frames[0].pc` is non-zero. Every frame has a non-empty `dso` (the test binary) and a `dso_offset` such that `segment_base + dso_offset == pc`. `handler_time_ns` is present and non-negative. | real |
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

`just phase2-test <variant>` switches `.worktree/phase2` to `phase2/<variant>`,
then builds and runs the tests in the build-env image
(`docker.io/apache/doris:build-env-ldb-toolchain-latest`):

```
just phase2-test common      # 8 pass, 6 skip (stub collector)
just phase2-test fp-walk     # 17 pass (14 common + 3 fp-walk-specific)
```

It runs `run-be-ut.sh --run --filter='*NativeStackActionTest.*' -j $(nproc)`
inside the image (test binary `doris_be_test`, build dir `be/ut_build_ASAN`).
The wildcard prefix is what makes `FpWalkNativeStackActionTest` (and future
per-variant suites) match.
Source and test files are auto-discovered by the existing `GLOB_RECURSE`, so no
CMake patch is needed.

The harness mounts the project root at its host path inside the container, so
git's `.git` pointers (worktree and submodules) resolve the same way on both
sides — no PATH shim is needed. `DORIS_THIRDPARTY=/var/local/thirdparty` reuses
the image's prebuilt thirdparty; it is never rebuilt.

The ASan UT build already enables `-fno-omit-frame-pointer`, so fp-walk needs no
build-flag patch.

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
