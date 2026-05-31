# Brief: ob-kill60 (Round 2, variant 1)

Second variant of the libunwind-class round. ck-phdr-unwind is the
calibration reference (4-patch series in patches/ck-phdr-unwind/,
verdict `baseline-pass`). This variant ships the OceanBase-derived
collector under the same common-api seam.

## Assignment

Implement and evaluate `ob-kill60`. Acceptance is by command:
`just phase2-test ob-kill60` reports all 14 cases from
`NativeStackActionTest` pass, on the real ob-kill60 collector
(none should GTEST_SKIP). `report.collector` is `"ob-kill60"` for every
dump. Zero failures, zero crashes, zero hangs.

Read the OceanBase upstream sources at:

- `<ob>/deps/oblib/src/lib/signal/ob_signal_worker.cpp`
- `<ob>/deps/oblib/src/lib/signal/ob_signal_handlers.cpp`
- `<ob>/deps/oblib/src/lib/signal/ob_signal_utils.cpp`

## Project Worktree

- Worktree: `/home/mira/lab/projects/Doris-BE-Print-Stack-API-Research/.worktree/phase2`.
- Branch to commit on: `phase2/ob-kill60` (create from `phase2/common`).
- Patches output: `/home/mira/lab/projects/Doris-BE-Print-Stack-API-Research/patches/ob-kill60/`.
- Evidence output: `/home/mira/lab/projects/Doris-BE-Print-Stack-API-Research/evidence/phase2/variants/ob-kill60/`.

## Fixed Inputs

- Base commit: `c24d454f15cee2d937ef4749270a3ecb449eafe6`.
- Build image: `docker.io/apache/doris:build-env-ldb-toolchain-latest` (already local).
- Common API patch set is frozen this round. Do not change
  `patches/common/*`. If a common-api change is needed, stop and report.
- Tier 2 is a later phase. Tier 1 is the only gate for this round.
- Async-signal safety is deferred. Document open questions; do not gate.
- Build through `just phase2-*` recipes only.

## Phase Model: Single-Phase Ack

**ob-kill60 ships single-phase.** Per
`docs/phase2-charter.md` and `docs/phase2-design.md`:

- The request thread signals each target with a per-request `req_id` in
  the SI_QUEUE payload.
- Each handler captures its frames into the slot AND returns
  immediately.
- The coordinator reads the slot after the handler exits and resolves
  DSO offsets.
- The worker NEVER hangs waiting for the coordinator.

This is the part that distinguishes ob-kill60 from a literal OceanBase
port. OceanBase's upstream form is two-phase (target thread hangs in
its handler until the coordinator acks; references in the design doc).
We deliberately drop the worker-hang because it is OB's main open risk
in our model. If your reading of `<ob>` suggests the single-phase form
fails some constraint OB needed, **stop and report** rather than
silently switching to two-phase.

## Allowed Writes

- `patches/ob-kill60/*` (you create this; harness exports via
  `just phase2-export ob-kill60`).
- `evidence/phase2/variants/ob-kill60/*` (manifest, commands, verdict,
  metrics, JSON sample).
- Inside the worktree, source needed by your patches (most likely: the
  re-enabled PHDR cache + init from Doris's existing commented-out
  scaffolding, the variant collect impl under
  `be/src/service/http/action/`, the Tier 2 jemalloc rebuild script).

## Forbidden Writes

- `patches/common/*`.
- `patches/fp-walk/*`, `patches/ck-phdr-unwind/*`.
- `docs/phase2-charter.md`, `docs/phase2-acceptance.md` (human-owned).
- Anything outside the project.

## Inherit-Then-Replace from ck-phdr-unwind

`patches/ck-phdr-unwind/` is your reference series. Two of its four
patches are libunwind / PHDR-cache infrastructure that ob-kill60 also
needs. Duplicate them into your series rather than refactoring them
into common this round:

- `patches/ck-phdr-unwind/0001-be-ck-phdr-unwind-enable-lock-free-dl_iterate_phdr-o.patch`
  → adapt to `patches/ob-kill60/0001-be-ob-kill60-…`.
- `patches/ck-phdr-unwind/0002-be-ck-phdr-unwind-populate-PHDR-cache-at-BE-startup.patch`
  → adapt to `patches/ob-kill60/0002-be-ob-kill60-…`.

The two collectors will share these patches verbatim or near-verbatim.
That duplication is intentional and short-lived: after
snapshot-remote-unwind also ships, a separate refactor task may
promote them into `patches/common/`. Until then, isolation matters
more than DRY.

The variant-specific work lives in patch 3 (collector) and patch 4
(build-system).

## Expected Patch Series

Aim for one logical change per patch:

1. `phdr-cache`: duplicate of ck-phdr-unwind's. Re-enables Doris's
   commented-out `dl_iterate_phdr` override.
2. `phdr-cache-init`: duplicate of ck-phdr-unwind's. Uncomment
   `updatePHDRCache()` at BE startup and in the test binary.
3. `native-stack-collector`: replace the stub `collect()` with OB-style
   single-phase collection. Signal: `SIGRTMIN + 6` queued via SI_QUEUE
   carrying a per-request `req_id`. Handler validates sender (`si_pid`)
   and `req_id`, captures PCs via libunwind into the common per-sequence
   slot, restores `errno`, and returns. Coordinator reads the slot after
   the handler exits, resolves DSO offsets per the existing
   `run_collection` flow. `report.collector = "ob-kill60"`.
4. `build-system`: Tier 2 jemalloc rebuild hook (same shape as
   ck-phdr-unwind's patch 0004). Opt-in CMake flag,
   `build-jemalloc-prof-libunwind.sh` script. Tier 1 keeps profiling OFF;
   the rebuild path ships ready but inert.

Citations:
`<ob>/deps/oblib/src/lib/signal/ob_signal_worker.cpp:280-347`
(OB's two-phase reference; we drop the worker-hang),
`<ob>/deps/oblib/src/lib/signal/ob_signal_handlers.cpp` (handler
mechanics, `safe_backtrace`),
`<ob>/deps/oblib/src/lib/signal/ob_signal_utils.cpp` (signal-utils
helpers if relevant).

Per-variant test file is **optional** and probably not needed:
ob-kill60's single-phase + libunwind has no analog to fp-walk's RBP
bounds or junk-RBP cases (libunwind walks DWARF, bounds are internal),
and the per-sequence slot ring semantics are tested via the inherited
case 12 (LateResponderDoesNotCorruptNextDump). If your handler has
ob-kill60-specific late-handler hazards you want a deterministic test
for, ship as `be/test/service/http/native_stack_action_test_ob_kill60.cpp`
with fixture `ObKill60NativeStackActionTest`. Otherwise omit.

## Common API State at HEAD

`patches/common/*` gives the variant:

- `run_collection` orchestration with the single-dump `std::timed_mutex`
  gate, bounded wait on `timeout_ms`, per-thread loop with deadline
  guard (`consume_deadline_budget_for_test` hook), `/proc/self/task`
  thread discovery, `resolve_dsos` + `serialize` after collection.
- Per-sequence slot ring with CAS `IDLE`→`PENDING` arming. Plug into
  the same ring; do not invent a different slot model.
- Test hooks declared in the common header:
  `set_unresponsive_tid_for_test`, `consume_deadline_budget_for_test`,
  `pause_handler_for_tid_for_test`. The first two are useful as-is.
  The third is fp-walk-specific WALKING semantics; ob-kill60 does not
  need it.

## Known Environment Facts

- Thirdparty is pre-built at `DORIS_THIRDPARTY=/var/local/thirdparty`.
  Do not rebuild it.
- libunwind in the linked archive exposes only `_ULx86_64_*` symbols
  (local-only). Define `UNW_LOCAL_ONLY` in your TU. ck-phdr-unwind's
  patch 0003 shows the pattern; copy it.
- `build.sh --be` may reach BE link and then fail in root `output/`
  packaging because of bind-mount permission preservation. Use
  `just phase2-test ob-kill60` instead.

## Required Output

Tracked under `evidence/phase2/variants/ob-kill60/`:

- `manifest.yaml`: commit SHAs of `phase2/ob-kill60`, patch list,
  image ID, build command, runtime command, variant-specific
  assumptions (single-phase rationale; PHDR cache init point; jemalloc
  rebuild on/off; what `<ob>` lines you cite).
- `commands.sh`: exact commands to reproduce build and test.
- `verdict.md`: `baseline-pass`, `hold`, or `fail`, with one paragraph
  per gate. On `hold` or `fail`, name the exact symptom and the
  file/line/log span that shows it.
- `sample-one-tid.json`: one small one-TID JSON sample.
- `build-facts.md`: libunwind symbol prefix confirmed, PHDR cache hit
  observed at handler time, jemalloc rebuild yes/no, the
  `<ob>` line ranges your collector cites.

Raw / ignored: full all-thread JSON, full build logs, full BE logs,
`/proc/<pid>/maps`, binaries, dumps. Write under
`evidence/phase2/raw/<run-id>/ob-kill60/` (gitignored).

## Acceptance Bar

`just phase2-test ob-kill60` reports:

- 14 cases from `NativeStackActionTest` pass on the real collector
  (none should GTEST_SKIP).
- 0 or more cases from `ObKill60NativeStackActionTest` pass
  (variant-specific; optional).
- Zero failures, zero crashes, zero hangs (`DumpLoopNoCrashNoStuck`
  finishes inside its wall-clock bound).

`report.collector` is `"ob-kill60"` for every dump.

Also: re-enroll the variant in
`scripts/phase2/_common.sh:VARIANTS="fp-walk ck-phdr-unwind ob-kill60"`
so the harness's export and rebase-all loops include it.

## Stop Conditions

Stop and report instead of improvising when:

- A change to `patches/common/*` is the only path forward.
- The common API contract (route, JSON shape, status names, busy/timeout
  semantics) needs to shift.
- The single-phase ack would skip a constraint that
  `<ob>/deps/oblib/src/lib/signal/ob_signal_worker.cpp` needed for
  correctness (some shared state guarded by the worker-hang). Report
  the specific OB line range and the constraint it carries.
- libunwind symbols do not resolve under `UNW_LOCAL_ONLY`.
- jemalloc's `--enable-prof-libunwind` rebuild needs a thirdparty
  change.
- `just phase2-test ob-kill60` reports a Tier 1 case as flaky.
- A timeout-tail or late-handler hazard appears that the common
  per-sequence ring should have caught.

When stopping, write a partial `verdict.md` with status `hold`, name
the blocker exactly, and leave the worktree on `phase2/ob-kill60`.

## Out of Scope This Round

- Tier 2 (jemalloc profiling on/off under alloc/thread/dlopen churn).
- Handler async-signal-safety review.
- Online symbolization.
- ADMIN/access-control.
- Refactor of duplicated PHDR cache + init patches into common — that
  is its own task after all 3 libunwind variants are green.
