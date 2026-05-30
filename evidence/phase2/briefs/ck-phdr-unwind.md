# Brief: ck-phdr-unwind (calibration variant)

This is the calibration variant of the libunwind-class round. Two more
variants (`ob-kill60`, `snapshot-remote-unwind`) fan out after this one
returns clean. Patches and build infrastructure introduced here should be
reusable by those two.

## Assignment

Implement and evaluate `ck-phdr-unwind`. Acceptance is by command:
`just phase2-test ck-phdr-unwind` must show 14 inherited cases from
`NativeStackActionTest` plus 0 or more variant-specific cases from
`CkPhdrUnwindNativeStackActionTest`, all pass. The harness filter is
already `*NativeStackActionTest.*`, so a per-variant fixture matches.

The dropped attempt-1 patches at `e3b5e2f^:patches/ck-phdr-unwind/` are
not your starting point. Their common-API target is gone and the seam is
different now. Read the ClickHouse upstream sources instead:

- `<ck>/base/base/phdr_cache.cpp`
- `<ck>/src/Storages/System/StorageSystemStackTrace.cpp`

## Project Worktree

- Worktree: `/home/mira/lab/projects/Doris-BE-Print-Stack-API-Research/.worktree/phase2`.
- Branch to commit on: `phase2/ck-phdr-unwind` (create from
  `phase2/common`).
- Patches output: `/home/mira/lab/projects/Doris-BE-Print-Stack-API-Research/patches/ck-phdr-unwind/`.
- Evidence output: `/home/mira/lab/projects/Doris-BE-Print-Stack-API-Research/evidence/phase2/variants/ck-phdr-unwind/`.

## Fixed Inputs

- Base commit: `c24d454f15cee2d937ef4749270a3ecb449eafe6`.
- Build image: `docker.io/apache/doris:build-env-ldb-toolchain-latest` (already local).
- Common API patch set is frozen this round. Do not change
  `patches/common/*`. If a common-api change is needed, stop and report.
- Tier 2 (jemalloc-profiling-on + alloc/thread/dlopen churn) is a later
  phase. Tier 1 is the only gate for this round.
- Async-signal safety is deferred. Document open questions; do not gate.
- Build through `just phase2-*` recipes only. Do not invoke `cmake`,
  `ninja`, `be/build.sh`, or `run-be-ut.sh` on the host.

## Allowed Writes

- `patches/ck-phdr-unwind/*` (you create this; the harness exports it
  via `just phase2-export ck-phdr-unwind`).
- `evidence/phase2/variants/ck-phdr-unwind/*` (manifest, commands,
  verdict, metrics, JSON sample).
- Inside the worktree, any source needed by your patches (most likely:
  one new PHDR-cache source under `be/src/`, the variant collect impl
  under `be/src/service/http/action/`, jemalloc build config under
  `be/CMakeLists.txt` or `thirdparty/`, the per-variant test file
  `be/test/service/http/native_stack_action_test_ck_phdr_unwind.cpp`).

## Forbidden Writes

- `patches/common/*` (frozen this round).
- `patches/fp-walk/*`.
- `docs/phase2-charter.md`, `docs/phase2-acceptance.md` (human-owned).
- Anything outside the project (no lab-side changes; lab summary is
  mira's after the dispatch completes).

## Common API State at HEAD

`patches/common/*` already gives the variant:

- `run_collection` orchestration: single-dump `std::timed_mutex` gate,
  bounded wait on `timeout_ms`, per-thread loop with a deadline guard
  (`consume_deadline_budget_for_test` hook for tests), `/proc/self/task`
  thread discovery, `resolve_dsos` + `serialize` after collection.
- Per-sequence slot ring with CAS `IDLE`→`PENDING` arming. Variant
  collectors plug into the same ring; do not invent a different slot
  model.
- Test hooks declared in the common header: `set_unresponsive_tid_for_test`,
  `consume_deadline_budget_for_test`, `pause_handler_for_tid_for_test`.
  The first two are useful as-is. The third is fp-walk-specific WALKING-
  state semantics; you may add a parallel hook for your handler if you
  ship a variant case 15-analog, but no common-api change is required.

## Expected Patch Series

Aim for one logical change per patch. A reasonable partition (you may
diverge with a one-line reason in the variant manifest):

1. `phdr-cache`: a `dl_iterate_phdr` cache so the handler-side libunwind
   avoids calling the loader. Mirrors `<ck>/base/base/phdr_cache.cpp`.
2. `phdr-cache-init`: install the cache at BE startup, before any
   libunwind use. Required so `unw_step`'s `dl_iterate_phdr` path hits
   the cache, not the loader.
3. `native-stack-collector`: replace the stub `collect()` with a real
   libunwind walk inside the realtime-signal handler. Pubishes into the
   common per-sequence slot. `report.collector = "ck-phdr-unwind"`.
4. `build-system`: link libunwind (defining `UNW_LOCAL_ONLY` because the
   shipped archive exposes local-only `_ULx86_64_*` symbols), and build
   jemalloc with `--enable-prof-libunwind` so its profiler uses
   libunwind (not libgcc), keeping the allocator off the conflicting
   path. Verify `backtrace_method = 'libunwind'` in jemalloc's
   `config.log`.
5. `tests-ck-phdr-unwind` (optional): a per-variant test file if you
   add libunwind-handler-specific cases (e.g. a slot-busy analog of
   case 15 using a handler-side pause that your collector implements).
   Ship as `be/test/service/http/native_stack_action_test_ck_phdr_unwind.cpp`
   with fixture `CkPhdrUnwindNativeStackActionTest`.

Citations: `<ck>/base/base/phdr_cache.cpp`,
`<ck>/src/Storages/System/StorageSystemStackTrace.cpp`. Doris already
builds Release with `-fno-omit-frame-pointer`; the ASan UT build does
too. Doris reference PR: apache/doris#22549. jemalloc upstream regression:
jemalloc#2504. Doris fix that motivated the cache: commit `96a46302e8c`.

## Known Environment Facts

- Thirdparty is pre-built at `DORIS_THIRDPARTY=/var/local/thirdparty`.
  Do not rebuild it unless you have to. If `--enable-prof-libunwind`
  requires a jemalloc rebuild, do it locally inside the worktree, not
  in thirdparty.
- libunwind in the linked archive exposes only `_ULx86_64_*` symbols
  (local-only). Define `UNW_LOCAL_ONLY` in your TU and confirm symbols
  resolve. Do not guess symbol prefixes from libunwind docs.
- `build.sh --be` may reach BE link and then fail in root `output/`
  packaging because of bind-mount permission preservation. Use
  `just phase2-test ck-phdr-unwind` instead; it builds via
  `run-be-ut.sh` and skips the packaging step.

## Required Output

Tracked under `evidence/phase2/variants/ck-phdr-unwind/`:

- `manifest.yaml`: commit SHAs of `phase2/ck-phdr-unwind`, patch list,
  image ID, build command, runtime command, variant-specific
  assumptions (e.g. PHDR cache init point, jemalloc rebuild yes/no).
- `commands.sh`: exact commands to reproduce build and test (the
  `just phase2-*` recipes you ran, in order).
- `verdict.md`: `baseline-pass`, `hold`, or `fail`, with one paragraph
  per gate (Tier 1 cases). On `hold` or `fail`, name the exact symptom
  and the file/line/log span that shows it.
- One small one-TID JSON sample (`sample-one-tid.json`).
- Build facts (`build-facts.md`): libunwind symbol prefix confirmed,
  jemalloc `config.log` line for `backtrace_method`, PHDR cache hit
  observed at handler time (`wc -l` of any debug counter you instrument).

Raw / ignored (do not commit; if produced, write under
`evidence/phase2/raw/<run-id>/ck-phdr-unwind/` and `.gitignore` it):
full all-thread JSON, full build logs, full BE logs, `/proc/<pid>/maps`,
binaries, dumps.

## Acceptance Bar

`just phase2-test ck-phdr-unwind` reports:

- 14 cases from `NativeStackActionTest` pass (these are the variant-
  agnostic cases inherited from `phase2/common`; they all need a real
  collector — none must GTEST_SKIP).
- 0 or more cases from `CkPhdrUnwindNativeStackActionTest` pass
  (variant-specific; optional).
- Zero failures, zero crashes, zero hangs (`DumpLoopNoCrashNoStuck`
  finishes inside its wall-clock bound).

`report.collector` is `"ck-phdr-unwind"` for every dump (proves the
stub is replaced).

## Stop Conditions

Stop and report instead of improvising when:

- A change to `patches/common/*` is the only path forward.
- The common API contract (route, JSON shape, status names, busy/timeout
  semantics) needs to shift.
- jemalloc's `--enable-prof-libunwind` rebuild needs a thirdparty
  change. Report the exact build line that fails.
- libunwind symbols do not resolve under `UNW_LOCAL_ONLY` despite the
  defined prefixes. Report the exact unresolved symbol.
- `just phase2-test ck-phdr-unwind` reports a Tier 1 case as flaky
  (passes on one run, fails on the next). Do not loop-until-green;
  report the timing margin.
- A timeout-tail or late-handler hazard appears that the common
  per-sequence ring should have caught. Report the case, the seq
  values you observed, and the slot state.

When stopping, write a partial `verdict.md` (status `hold`) naming the
blocker exactly, and leave the worktree on `phase2/ck-phdr-unwind` so
the next round can `git switch` into your in-flight state.

## Out of Scope This Round

- Tier 2 (jemalloc profiling on/off under alloc/thread/dlopen churn).
  A later phase exercises all variants under Tier 2; do not try to
  green it here.
- Handler async-signal-safety review. Charter defers it to the phase
  that evaluates the libunwind variants as a whole — code-review and
  TSan/ASan matter, not a green Tier 1 test.
- Online symbolization. Charter forbids it.
- ADMIN/access-control changes. The route stays ADMIN-guarded via the
  existing `NativeStackAction` registration; no security regression and
  no scope expansion.
