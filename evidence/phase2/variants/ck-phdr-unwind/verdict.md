# ck-phdr-unwind — Tier 1 Verdict

**Status: `baseline-pass`**

`just phase2-test ck-phdr-unwind` runs all 14 cases from `NativeStackActionTest`.
Three back-to-back runs all green; zero failures, zero crashes, zero hangs.
`DumpLoopNoCrashNoStuck` (case 13) finishes 200 iterations in ~940 ms, well
inside its 60-second wall-clock bound. `report.collector` is `"ck-phdr-unwind"`
in every dump (see `sample-one-tid.json`).

No variant-specific `CkPhdrUnwindNativeStackActionTest` cases are shipped this
round; the brief listed the per-variant test patch as optional and cases 14
(RBP bounds), 15 (WALKING-state slot-busy), 17 (junk-RBP mincore) are fp-walk-
specific handler-state mechanics. libunwind walks DWARF, not raw frame
pointers, so it carries no analog to those guards; a parallel test set would
add no coverage.

## Per-gate paragraphs

### Contract (cases 1-6)

`Schema`, `ShapeOneTid`, `MissingTid`, `BadRequest`,
`ContendedDumpReturnsTimeout`, `Timeout` all pass. The collector name
field carries `"ck-phdr-unwind"` (verified via `sample-one-tid.json`),
required root + per-thread keys are present, no symbol-like keys leak,
each frame carries exactly `pc`/`dso`/`dso_offset`. The contended-dump
case acquires the `s_dump_mutex` from another thread for 20 ms and the
concurrent collect returns `"timeout"`, then the next collect succeeds.

### Correctness (cases 7-11)

`NonZeroPcPerActiveThread`, `KnownChainResolved`, `Truncated`,
`SignalBlocked`, `PartialResults` all pass. Critically:

- **`KnownChainResolved`** (case 8) confirms the libunwind walk
  produces the recorded `__builtin_return_address` chain as a contiguous
  subsequence beginning at `frames[1]` or `frames[2]` (the test plan's
  exact acceptance window). The dso_offset formula
  `segment_base + dso_offset == pc` holds for every frame.
- **`Truncated`** (case 9) confirms `truncated=true` at `max_frames=4`
  and `truncated=false` at `max_frames=256`. The collector's
  approximation (`truncated = (n == max_frames)`) is conservative
  enough for the test's bounded chain.
- **`SignalBlocked`** (case 10) confirms `is_signal_blocked` reads
  `SigBlk:` from /proc and reports the variant-specific status
  `"signal_blocked"` instead of `"timeout"` for a thread that masks
  SIGRTMIN+6.

### Boundary (case 12)

`LateResponderDoesNotCorruptNextDump` passes. The per-sequence slot
ring with token + state-machine CAS guarantees the second dump's
ThreadStack carries the correct tid even though the first dump's
handler ran on the same target thread. Deterministic deepening is the
Tier 2 TSan run.

### Stability (case 13)

`DumpLoopNoCrashNoStuck` passes. 200 iterations finish in ~940 ms; the
BE stays alive; all workers stay joinable. No crash, no deadlock, no
stuck thread. The libunwind walk path runs cleanly under the lock-free
PHDR cache override (the cache is populated by `run_all_tests.cpp:109`
before RUN_ALL_TESTS).

### Stability tail (case 16)

`DeadlineGuardSkipsExpiredSignaling` passes. After
`consume_deadline_budget_for_test(80)` drains 80 ms before a 50 ms
timeout, every per-thread entry carries the
`"dump deadline expired before signaling this thread"` reason from
the common run_collection guard; no `"ok"` slips through, and the
elapsed wall-clock stays close to `timeout_ms + consume_ms` (well
under the 200 ms upper bound).

## Stop Conditions

None triggered.

- `patches/common/*` not modified.
- common API contract unchanged.
- jemalloc rebuild deferred (Tier 2 + brief explicitly defers); the
  rebuild path is shipped as opt-in (see patch 0004 and `build-facts.md`).
- libunwind symbols resolve under `UNW_LOCAL_ONLY` (TU-scoped).
- No flake observed across 3 consecutive runs.
- No timeout-tail / late-handler hazard observed.

## Tier 1 case ledger

| # | name | status |
|--:|--|--|
| 1 | Schema | pass |
| 2 | ShapeOneTid | pass |
| 3 | MissingTid | pass |
| 4 | BadRequest | pass |
| 5 | ContendedDumpReturnsTimeout | pass |
| 6 | Timeout | pass |
| 7 | NonZeroPcPerActiveThread | pass |
| 8 | KnownChainResolved | pass |
| 9 | Truncated | pass |
| 10 | SignalBlocked | pass |
| 11 | PartialResults | pass |
| 12 | LateResponderDoesNotCorruptNextDump | pass |
| 13 | DumpLoopNoCrashNoStuck | pass (937-939 ms / 200 iter) |
| 16 | DeadlineGuardSkipsExpiredSignaling | pass (80 ms total) |

14 / 14 pass. Zero failures, zero crashes, zero hangs.
