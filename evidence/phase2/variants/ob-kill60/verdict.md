# ob-kill60 — Tier 1 Verdict

**Status: `baseline-pass`**

`just phase2-test ob-kill60` runs all 14 cases from `NativeStackActionTest`.
Three back-to-back runs all green; zero failures, zero crashes, zero hangs.
`DumpLoopNoCrashNoStuck` (case 13) finishes 200 iterations in ~940 ms, well
inside its 60-second wall-clock bound. `report.collector` is `"ob-kill60"`
in every dump (see `sample-one-tid.json`).

No variant-specific `ObKill60NativeStackActionTest` cases are shipped this
round; the brief listed the per-variant test patch as optional. Cases 14
(RBP bounds), 15 (WALKING-state slot-busy), 17 (junk-RBP mincore) are
fp-walk-specific handler-state mechanics. libunwind walks DWARF, not raw
frame pointers, so it carries no analog to those guards; the inherited
case 12 (`LateResponderDoesNotCorruptNextDump`) already exercises the
per-sequence slot ring under the single-phase model.

## Single-phase ack — variant rationale

ob-kill60 ships the **single-phase** form: the signal handler captures
the interrupted thread's frames via libunwind and returns immediately.
The coordinator polls the per-sequence slot until it transitions to
`SLOT_DONE`, then copies the frames out. The worker thread NEVER hangs.

This is the deliberate divergence from OceanBase's upstream two-phase
form, which has the worker block inside `ObSigHandler::handle`
(`<ob>/deps/oblib/src/lib/signal/ob_signal_worker.cpp:349-385`) reading
a pipe from the coordinator until the coordinator finishes its
`processor_->process()` call. Per `docs/phase2-charter.md` and the
per-variant brief, that worker-hang is OB's main open risk in this
evaluation: a worker pinned in its handler delays every other RPC the
BE serves. The single-phase form captures everything inline so the
worker resumes immediately, trading OB's
register/stack-still-live invariant (which OB uses to let the
coordinator run async-signal-unsafe ASH/SQL_INFO export against the
worker's frames) for shorter handler-to-resume time.

The OB constraint the single-phase form preserves is the **token
validation pattern**: the handler reads `req_id` from
`info->si_value.sival_ptr` and drops if `req_id != ctx.req_id_`
(`<ob>/.../ob_signal_handlers.cpp:113-114`). ob-kill60 transcribes this
as the `seq != slot.expected_seq` check at handler entry, so stale
handlers from prior dumps cannot corrupt the live slot. The OB
constraint the single-phase form drops is the **two-phase exchange**
(prepare-ack pipe + exit-ack pipe), because the captured payload is
the PC array, not a live-thread reference — once the array is
published into the slot, the worker has nothing more to contribute.

## Per-gate paragraphs

### Contract (cases 1-6)

`Schema`, `ShapeOneTid`, `MissingTid`, `BadRequest`,
`ContendedDumpReturnsTimeout`, `Timeout` all pass. The collector name
field carries `"ob-kill60"` (verified via `sample-one-tid.json`),
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
  `segment_base + dso_offset == pc` holds for every frame. Same window
  ck-phdr-unwind hits, because both variants seed libunwind from the
  same saved `ucontext_t` with `UNW_INIT_SIGNAL_FRAME`.
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
handler ran on the same target thread. Under single-phase ack the
handler exits promptly, so the late-handler hazard window is narrower
than under OB's upstream two-phase form (where a stuck worker keeps
the slot busy for the whole pipe-exchange duration). The ring is the
shared safety mechanism that makes both phase models safe.

### Stability (case 13)

`DumpLoopNoCrashNoStuck` passes. 200 iterations finish in ~940 ms; the
BE stays alive; all workers stay joinable. No crash, no deadlock, no
stuck thread. The libunwind walk path runs cleanly under the lock-free
PHDR cache override (the cache is populated by `run_all_tests.cpp:109`
before RUN_ALL_TESTS). Wall-clock envelope matches ck-phdr-unwind
(~930 ms across both variants) — single-phase ack does not materially
change Tier 1 timing because Tier 1 tests do not stress the
coordinator wait path.

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
- common API contract unchanged (route, JSON shape, status names,
  busy/timeout semantics preserved).
- Single-phase ack did NOT trigger any constraint OB's two-phase form
  requires for correctness. The OB `req_id`/`si_pid` validation
  pattern is preserved verbatim. The OB worker-hang's purpose (keeping
  the worker's registers/stack live for the coordinator's
  `processor_->process()` call) does not apply: ob-kill60's
  coordinator only consumes the published PC array, not a live-thread
  reference. See verdict prose above for the contrast analysis.
- jemalloc rebuild deferred (Tier 2 + brief explicitly defers); the
  rebuild path is shipped as opt-in (see patch 0004 and `build-facts.md`).
- libunwind symbols resolve under `UNW_LOCAL_ONLY` (TU-scoped). Same
  `#define UNW_LOCAL_ONLY` pattern OB uses in `ob_libunwind.c:15-16`.
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
| 13 | DumpLoopNoCrashNoStuck | pass (930-942 ms / 200 iter) |
| 16 | DeadlineGuardSkipsExpiredSignaling | pass (80 ms total) |

14 / 14 pass. Zero failures, zero crashes, zero hangs.
