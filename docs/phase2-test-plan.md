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

## File and partition

- One file: `be/test/service/http/native_stack_action_test.cpp`. It ships as a
  `tests-` patch in `patches/common/`, so it is present for every variant
  (`phase2_patches.sh` applies common first, then the variant).
- Fixture: `NativeStackActionTest`.
- A case that needs a real collector starts with
  `if (report.collector == "stub") GTEST_SKIP();`. So `just phase2-test
  common-api` runs the contract subset green, and `just phase2-test fp-walk`
  runs everything.

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
| 8 | Correctness | `KnownChainResolved` | spawn the marker chain (entry, c, b, a, spin); collect `{tid:T}`. `frames[1..4].pc` equal the recorded `__builtin_return_address(0)` values, in caller order; `frames[0].pc` is non-zero. Every frame has a non-empty `dso` (the test binary) and a `dso_offset` such that segment base plus offset equals `pc`. `handler_time_ns` is present and non-negative. | real |
| 9 | Correctness | `Truncated` | spawn a chain deeper than N; collect `{tid:T, max_frames:N}`. `frames.size() == N`, `truncated == true`. Control: a large N gives `truncated == false`. | real |
| 10 | Correctness | `SignalBlocked` | a thread blocks `SIGRTMIN+6` with `pthread_sigmask`, then parks; collect `{tid:T}`. Status `signal_blocked`, not `timeout`. | real |
| 11 | Correctness | `PartialResults` | spawn responsive parked threads plus one unresponsive (`set_unresponsive_tid`); collect all. Responsive threads carry frames, the unresponsive one is `timeout`, overall status `partial`, process healthy. | real |
| 12 | Boundary | `LateResponderDoesNotCorruptNextDump` | make T run its handler after dump 1's deadline, so dump 1 marks T `timeout`; run dump 2 with a new sequence number; when T's late handler fires, dump 2 is uncorrupted, T is not misattributed, no crash. Proves the sequence guard drops the stale write. | real |
| 13 | Stability | `DumpLoopNoCrashNoStuck` | collect all in a loop of N iterations (about 200) with the marker threads alive. Every iteration returns, the loop finishes within a wall-clock bound, all workers stay joinable. | stub + real |

## Candidates

Cases worth adding once the baseline is green:

- `MaxStackBytesBound`: set a small `max_stack_bytes` and confirm the frame-
  pointer walk stops at the bound without reading past it. The charter bounds
  copied stack bytes, but no Tier 1 case exercises that bound yet.

## The recipe

There is no `phase2-test` recipe yet. Add one:

```
just phase2-test <variant>:
  scripts/phase2_patches.sh apply <variant>   # common first, then the variant
  build the BE unit-test target in the build-env image
  run the test binary with --gtest_filter='NativeStackActionTest.*'
```

The build-env image is `docker.io/apache/doris:build-env-ldb-toolchain-latest`.
The test target name and the single-test run command are confirmed against
`be/test` before the recipe is written.

## Tier 2 (deferred, not in this file)

These are scripted and replayable, per [phase2-acceptance.md](phase2-acceptance.md).
They are not part of the baseline.

- jemalloc profiling on, then off, under a dump loop.
- allocation pressure during a dump loop.
- thread create and exit churn.
- `dlopen` and `dlclose` churn.
- the use-after-free half of case 12, under ASan. Tier 1 proves no
  misattribution; ASan proves no use-after-free.
