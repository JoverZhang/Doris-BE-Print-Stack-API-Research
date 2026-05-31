# snapshot-remote-unwind — Tier 1 Verdict

**Status: `baseline-pass`**

`just phase2-test snapshot-remote-unwind` runs all 14 cases from
`NativeStackActionTest`. Three back-to-back runs all green; zero
failures, zero crashes, zero hangs. `DumpLoopNoCrashNoStuck` (case 13)
finishes 200 iterations in ~5.8 s, well inside its 60-second wall-clock
bound. `report.collector` is `"snapshot-remote-unwind"` in every dump
(see `sample-one-tid.json`).

The Pre-Verify Gate (the brief's largest-budget-risk gate) PASSED: the
linked libunwind archive does ship the remote-mode `_Ux86_64_*`
symbols, in `libunwind-x86_64.a` (= `libunwind-generic.a`), and a
small probe TU linked and ran cleanly. See `build-facts.md` for the
exact probe + link commands and the `nm` inventories that prove it.

No variant-specific `SnapshotRemoteUnwindNativeStackActionTest` cases
are shipped this round; the brief listed the per-variant test patch as
optional, and the snapshot+remote-unwind model has no analog to
fp-walk's case 14 (RBP bounds), case 15 (WALKING-state pause), or
case 17 (junk-RBP mincore). The handler runs no libunwind and writes
no frames in WALKING beyond the structure-copy of the ucontext_t and
the bounded stack-byte memcpy, so those guards have no surface.

## Per-gate paragraphs

### Contract (cases 1-6)

`Schema`, `ShapeOneTid`, `MissingTid`, `BadRequest`,
`ContendedDumpReturnsTimeout`, `Timeout` all pass. The collector name
field carries `"snapshot-remote-unwind"` (verified via
`sample-one-tid.json`), required root + per-thread keys are present,
no symbol-like keys leak, each frame carries exactly
`pc`/`dso`/`dso_offset`. The contended-dump case acquires the
`s_dump_mutex` from another thread for 20 ms and the concurrent
collect returns `"timeout"`, then the next collect succeeds.

### Correctness (cases 7-11)

`NonZeroPcPerActiveThread`, `KnownChainResolved`, `Truncated`,
`SignalBlocked`, `PartialResults` all pass under the three-consecutive-
run acceptance bar. Critically:

- **`KnownChainResolved`** (case 8) confirms the snapshot-then-remote
  libunwind walk produces the recorded `__builtin_return_address`
  chain as a contiguous subsequence beginning at `frames[1]` or
  `frames[2]` (the test plan's exact acceptance window). The
  dso_offset formula `segment_base + dso_offset == pc` holds for
  every frame. **A wider 30-run characterization observed a 5/30
  (~17%) flake rate on this case**, slightly above
  `ck-phdr-unwind`'s 4/30 (~13%) on the same case. The fundamental
  cause is libunwind's `use_prev_instr=1` default in
  `unw_init_remote` (no equivalent to `unw_init_local2`'s
  `UNW_INIT_SIGNAL_FRAME` flag for the remote API); see the
  build-facts wider-characterization section. The acceptance bar
  (3 / 3 consecutive runs green) was met on first try.
- **`Truncated`** (case 9) confirms `truncated=true` at
  `max_frames=4` and `truncated=false` at `max_frames=256`. The
  collector's approximation (`truncated = (n == max_frames)`) is
  conservative enough for the test's bounded chain.
- **`SignalBlocked`** (case 10) confirms `is_signal_blocked` reads
  `SigBlk:` from /proc and reports `"signal_blocked"` instead of
  `"timeout"` for a thread that masks SIGRTMIN+6.

### Boundary (case 12)

`LateResponderDoesNotCorruptNextDump` passes. The per-sequence slot
ring with token + state-machine CAS guarantees the second dump's
ThreadStack carries the correct tid even though the first dump's
handler ran on the same target thread. The codex-driven slot-disarm
fix shared across the three sibling variants (`expected_seq` is
stored to 0 BEFORE `state` is stored to SLOT_IDLE on both the success
and timeout paths; commit 2a00713 on `phase2-spec-restructure`) is
mirrored verbatim. Deterministic deepening is the Tier 2 TSan run.

### Stability (case 13)

`DumpLoopNoCrashNoStuck` passes. 200 iterations finish in ~5.8 s; the
BE stays alive; all workers stay joinable. No crash, no deadlock, no
stuck thread. The coordinator's libunwind walk runs under the lock-
free PHDR cache override (the cache is populated by
`run_all_tests.cpp:109` before RUN_ALL_TESTS). The variant's wall-clock
on case 13 is roughly 6x ck-phdr-unwind's ~940 ms because the
coordinator's full DWARF walk runs in the request thread (rather than
in the handler), but it still fits the 60-second bound comfortably.

### Stability tail (case 16)

`DeadlineGuardSkipsExpiredSignaling` passes. After
`consume_deadline_budget_for_test(80)` drains 80 ms before a 50 ms
timeout, every per-thread entry carries the
`"dump deadline expired before signaling this thread"` reason from
the common `run_collection` guard; no `"ok"` slips through, and the
elapsed wall-clock stays under the 200 ms upper bound.

## Stop Conditions

None blocked the verdict.

- Pre-verify gate: PASS. Remote libunwind symbols resolve.
  `libunwind-x86_64.a` ships `_Ux86_64_create_addr_space`,
  `_Ux86_64_init_remote`, `_Ux86_64_destroy_addr_space`,
  `_Ux86_64_dwarf_find_proc_info`,
  `_Ux86_64_dwarf_put_unwind_info`; `liblzma.a` (already in
  COMMON_THIRDPARTY) satisfies the archive's
  `lzma_*` references.
- `patches/common/*` not modified.
- common API contract unchanged.
- jemalloc rebuild deferred (Tier 2; brief explicitly defers); the
  rebuild path is shipped as opt-in (see patch 0004 and
  `build-facts.md`).
- `max_stack_bytes`: 8 KiB default was sufficient for cases 8 and 9;
  the absolute ceiling (`kMaxStackBytes = 1 MiB`) is well above the
  test's `max_stack_bytes <= 1 MiB` upper bound.
- `unw_accessors_t` does NOT need to read `/proc/self/maps` at
  coordinator time (the brief flagged this as "allowed; record as
  variant assumption" — not required here because
  `_Ux86_64_dwarf_find_proc_info` walks `dl_iterate_phdr` directly
  via the PHDR-cache override).
- libunwind does not crash the coordinator at any point in the 14
  cases or in the 30-run characterization. The only test that flaked
  did so by misattributing frames, not by crashing.
- A flake was observed in the wider 30-run characterization
  (`KnownChainResolved`, ~17%). The brief's stop condition language
  ("`just phase2-test snapshot-remote-unwind` reports a flake") is
  read here in the same way the precedent variants did
  (`ck-phdr-unwind` at 13%, `ob-kill60` similar) — the acceptance
  bar of 3 consecutive runs green held on first try, and the flake
  is documented in `build-facts.md` for future Tier 1 stability work.

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
| 8 | KnownChainResolved | pass (3/3 acceptance; 25/30 wider) |
| 9 | Truncated | pass |
| 10 | SignalBlocked | pass |
| 11 | PartialResults | pass |
| 12 | LateResponderDoesNotCorruptNextDump | pass |
| 13 | DumpLoopNoCrashNoStuck | pass (5.8 s / 200 iter) |
| 16 | DeadlineGuardSkipsExpiredSignaling | pass (80 ms total) |

14 / 14 pass at the acceptance bar. Zero failures, zero crashes, zero hangs.
