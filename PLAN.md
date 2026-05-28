# Doris BE Stack Collection Plan

## Goal

Choose one Doris BE live native stack collection design.

This phase compares four designs:

- `ck-phdr-unwind`
- `ob-kill60`
- `snapshot-remote-unwind`
- `fp-walk`

Each design must use the same debug API.
Each design must start from the same Doris base commit.
Each design must run through the same test matrix.

The output is one of these results:

- Select one design for the next Doris BE implementation step.
- Select no design, if no design passes the required gates.

This phase does not produce the final production PR.
This phase does not include online symbolization.

## Decision

Answer this question:

Which design should Doris use to collect live BE native stacks?

The decision report must include:

- The selected design, or `none`.
- The reason for the selection.
- The reason each other design was rejected.
- The evidence path for each design.
- The risks that remain after the decision.

The decision must judge:

- Signal-handler safety.
- Correctness of collected PCs and DSO offsets.
- API latency.
- Worker pause time.
- Behavior under query load.
- Behavior with jemalloc profiling.
- Change size inside Doris.
- Maintenance cost inside Doris.

## Variants

Test four variants:

- `ck-phdr-unwind`
  - Interrupt workers with `rt_tgsigqueueinfo`.
  - Run `libunwind` in the signal handler.
  - Add PHDR cache support.
  - Symbolize offline.

- `ob-kill60`
  - Interrupt workers with `rt_tgsigqueueinfo`.
  - Collect PCs in the signal handler.
  - Let the coordinator compute DSO offsets.
  - Keep the OceanBase-style two-phase control flow first.

- `snapshot-remote-unwind`
  - Interrupt workers with `rt_tgsigqueueinfo`.
  - Copy register state and stack bytes in the signal handler.
  - Let the coordinator unwind from the snapshot.
  - Avoid `libunwind` work inside the worker signal handler.

- `fp-walk`
  - Use Doris Release build flags.
  - Use RIP and RBP to walk frames.
  - Require `-fno-omit-frame-pointer`.
  - Avoid DWARF unwind in the signal handler.

## Common API

Expose the same debug API in every variant.

The API must:

- Return raw PCs.
- Return DSO offsets.
- Avoid online symbolization.
- Support all threads by default.
- Support one target thread by TID.
- Allow only one active dump at a time.
- Return `busy` when another dump is running.
- Require ADMIN permission.
- Work on Linux x86_64 Release builds.

Use these default limits:

- Timeout: `100ms`.
- Max frames per thread: `64`.
- Max copied stack bytes: `8KiB`.

The API response must identify:

- Request status.
- Target TID, when the request targets one thread.
- Per-thread status.
- Per-thread frames.
- Per-thread truncation state.
- Per-thread error reason, when a thread fails.
- API elapsed time.

The API response must not include:

- Function names.
- Source file names.
- Source line numbers.
- Demangled names.

Only offline evidence may contain symbols, source files, and line numbers.

## Work Sequence

Run the work in this order.

1. Build the common API first.
   - Start from the shared Doris base commit.
   - Add only shared API code, ADMIN permission checks, busy handling, timeout handling, JSON shape, and test helpers.
   - Do not add variant-specific stack collection yet.
   - This gate passes when Doris builds, BE starts, and the API returns the agreed JSON shape from a stub or minimal collector.

2. Build one pilot variant.
   - Use `fp-walk` as the default pilot unless there is a clear reason to choose another variant.
   - The pilot must use the common API without changing the API contract.
   - This gate passes when the pilot builds, starts BE, returns real frames, supports offline symbolization, handles repeated dumps, and writes complete evidence.

3. Build the remaining variants in parallel.
   - Start parallel subagents only after the common API gate and pilot gate pass.
   - Each subagent owns one variant only.
   - Each subagent may edit only its Doris worktree, its patch directory, and its evidence directory.
   - Shared API changes after the pilot require review before they are copied to other variants.

4. Review each variant.
   - Review the patch series.
   - Review the evidence package.
   - Record `pass`, `fail`, or `hold`.

5. Compare reviewed variants.
   - Compare only variants with `pass` or final-review accepted `fail`.
   - Select one design or select `none`.
   - Write the final decision record.

## Acceptance Criteria

A variant passes only when it passes every required check below.

Build and setup:

- The variant builds `doris_be` from base commit `c24d454f15cee2d937ef4749270a3ecb449eafe6`.
- The evidence records the exact patch series, compiler flags, linked unwind libraries, and jemalloc settings.
- The Release build keeps frame pointers when the variant depends on frame-pointer walking.

API behavior:

- The debug API returns JSON for all threads.
- The debug API returns JSON for one target TID.
- The API returns `busy` when another dump is active.
- The API rejects callers without ADMIN permission.
- The API returns a clear status for timeout, missing TID, and exited thread.
- The API returns raw PCs and DSO offsets only.
- The API does not return function names, file names, line numbers, or demangled names.

Frame usefulness:

- Each successful active worker thread returns at least one non-zero PC.
- At least one known-stack test thread returns the expected function chain after offline symbolization.
- Each DSO offset matches the DSO path and build ID recorded for that frame.
- Truncated stacks are marked as truncated.

Safety:

- The BE does not crash during repeated dumps.
- The BE does not deadlock during repeated dumps.
- Workers resume after the dump ends.
- The variant records handler time or explains why handler time cannot be measured.
- Signal-handler code does not allocate memory, take locks, call symbolization code, or call unsafe logging.

Load behavior:

- The variant completes dumps during the chosen Doris query workload.
- The evidence records API latency p50, p95, p99, and max.
- The evidence records worker pause p50, p99, and max when measurable.
- The evidence records query errors and relevant BE log lines.

Jemalloc behavior:

- The variant passes the repeated dump test with jemalloc profiling disabled.
- The variant passes the repeated dump test with jemalloc profiling enabled.
- The variant passes dump tests during allocation pressure.

A variant fails when it:

- Crashes Doris.
- Deadlocks Doris.
- Leaves workers stopped.
- Returns corrupt frame data.
- Needs unguarded unsafe global state.
- Cannot run with jemalloc profiling enabled.

## Test Matrix

Run every required row for every variant.

| Area | Test | Required evidence | Pass rule |
| --- | --- | --- | --- |
| Build | Release build | build output, compiler flags, linked libraries | `doris_be` builds |
| Build | Frame-pointer check | compile command sample | Required flags exist for `fp-walk` |
| API | All-thread dump | request, response JSON | Status is `ok`; active workers have frames |
| API | One-TID dump | chosen TID, response JSON | Only the target TID is dumped |
| API | Concurrent dump | two overlapping requests | One request returns `busy` |
| API | Permission check | non-ADMIN request | Request is rejected |
| API | Timeout check | low-timeout request | Timeout status is returned, and BE stays healthy |
| API | Missing-TID check | request for missing TID | Missing-TID status is returned |
| API | No-symbol check | response JSON | No function, file, line, or demangled fields exist |
| Correctness | Known-stack thread | API JSON, offline symbolization output | Expected frame chain appears |
| Correctness | DSO offset check | `/proc/<pid>/maps`, build IDs, offline command | Offsets symbolize against matching objects |
| Repeat | Dump loop | iteration count, failures, BE log excerpt | No crash, no deadlock, no stuck worker |
| Load | Query workload plus dump | workload command, latency metrics, BE log excerpt | Queries continue; errors are explained |
| Load | Allocation pressure | workload command, latency metrics | No crash and no deadlock |
| Risk | Controlled `dlopen` and `dlclose` churn | test command, BE log excerpt, result | No deadlock; PHDR behavior is recorded |
| Risk | Thread create and exit churn | test command, status counts | Exited threads do not corrupt the dump |
| Jemalloc | Profiling off | env, result | Pass |
| Jemalloc | Profiling on | env, result | Pass |
| Variant data | Variant-specific metrics | extra CSV or notes | Used only to explain the verdict |

Use the same workload settings for all variants.
Record any skipped row as `SKIPPED` with a reason.
A skipped required row blocks the final recommendation.

## Patch, Evidence, and Review Layout

The parent repository stores the durable record.

Use this layout:

- `patches/common/`
  - Patch series for shared API and shared test helpers.
- `patches/<variant>/`
  - Patch series for one variant only.
  - Generate it relative to the common branch.
- `evidence/phase2/README.md`
  - How to read the evidence package.
- `evidence/phase2/matrix.csv`
  - One row per variant and test.
- `evidence/phase2/decision.md`
  - Final comparison and selected result.
- `evidence/phase2/shared/`
  - Shared base commit, host, build image, workload, and API schema.
- `evidence/phase2/variants/<variant>/`
  - One evidence package per variant.
- `reviews/<variant>.md`
  - Review of one variant.
- `reviews/final-comparison.md`
  - Cross-variant review.

Required files for each variant:

- `manifest.yaml`: variant name, base commit, common head, variant head, host, build image, Doris config, and jemalloc config.
- `patches/`: copied patch series for review.
- `commands.sh`: exact commands used for build, run, tests, and offline symbolization.
- `build-output/build.txt`: full build output.
- `build-output/compile-flags.txt`: sampled compile commands for stack-related objects.
- `api/all-threads.json`: sample all-thread API response.
- `api/one-tid.json`: sample target-TID API response.
- `api/busy.json`: concurrent dump result.
- `api/permission-denied.json`: non-ADMIN result.
- `api/timeout.json`: timeout result.
- `api/missing-tid.json`: missing-TID result.
- `correctness/known-stack.json`: raw API output for the known-stack test.
- `correctness/offline-symbolization.txt`: offline result for the known-stack PCs.
- `correctness/maps.txt`: `/proc/<pid>/maps` for the tested BE.
- `correctness/build-ids.txt`: object build IDs used by offline tools.
- `repeat/result.md`: dump-loop count, failures, crash count, and stuck-worker count.
- `load/metrics.csv`: latency, pause, frame count, timeout count, and error count.
- `load/be-log.txt`: relevant BE log excerpt.
- `risk/dlopen.md`: controlled DSO churn result.
- `risk/thread-churn.md`: thread create and exit result.
- `jemalloc/off.md`: result with profiling disabled.
- `jemalloc/on.md`: result with profiling enabled.
- `verdict.md`: pass or fail summary, known risks, and recommendation.

Use these columns in `evidence/phase2/matrix.csv`:

- `variant`
- `test`
- `status`
- `api_p99_ms`
- `api_max_ms`
- `pause_p99_us`
- `pause_max_us`
- `threads_ok`
- `threads_timeout`
- `median_frames`
- `crash_count`
- `deadlock_count`
- `log_errors`
- `notes`

Only offline evidence may contain function names, source files, or line numbers.
The API evidence must contain raw PCs and DSO offsets only.

Durable evidence must use tracked paths.
Do not use ignored directories such as `build/`.
Do not use ignored file names such as `*.log`.

Regenerate patch directories from scratch when exporting patches.
This avoids stale patch files.

A patch series is valid only when it can replay from the base commit:

1. Apply `patches/common/*.patch`.
2. Apply `patches/<variant>/*.patch`.
3. Build Doris.
4. Run the same test matrix.

## Decision Rule

First, apply the required gates.

A design is eligible only if it:

- Builds `doris_be`.
- Starts a local BE.
- Returns stack dump JSON from the debug API.
- Returns raw PCs and DSO offsets.
- Produces PCs that offline tools can symbolize.
- Respects the timeout.
- Does not deadlock Doris.
- Does not crash Doris.
- Does not leave workers blocked after the dump.
- Does not corrupt stack data.
- Works with jemalloc profiling enabled.

Select `none` if no design passes these gates.
Then document the blocking risks and the next experiment.

Rank eligible designs in this order:

1. Lowest signal-handler risk.
2. Most predictable timeout behavior.
3. Lowest worker pause time.
4. Best useful frame coverage for real BE debugging.
5. Smallest Doris code change.
6. Lowest long-term maintenance cost.

Reject a design when its main risk cannot be reduced inside Doris.

Do not use repository layout as a decision factor.
Do not choose a design because it would make online symbolization easier.
Online symbolization is a later goal.

## Review Workflow

Review each variant before comparing designs.

For each variant, check:

- The variant starts from the same base commit.
- The common patch series is included.
- The variant patch series replays cleanly.
- Doris builds.
- The API response matches the common schema.
- All required evidence files exist.
- Failures are recorded, not hidden.
- Known risks are written in clear language.

Write one review file per variant.

Use `hold` when evidence is incomplete.
Use `fail` when the design breaks a fail condition.
Use `pass` when the variant has enough evidence for final comparison.

Only compare variants after all four reviews are `pass` or final-review accepted `fail`.

## Open Questions

Resolve these questions before the final decision:

- `ck-phdr-unwind`: Can Doris keep the PHDR cache correct when shared libraries load and unload?
  Evidence: Run the shared-library risk test. Record cache updates, DSO offsets, and failures.
  Decision effect: Reject this design if cache correctness needs unsafe signal-handler work.

- `ob-kill60`: Does this design pause workers while the coordinator computes DSO offsets?
  Evidence: Measure worker pause time and API latency during load.
  Decision effect: Lower its rank or reject it if the pause exceeds the timeout goal.

- `snapshot-remote-unwind`: How many stack bytes should the signal handler copy?
  Evidence: Compare frame count, latency, and failures for the default size and larger sizes.
  Decision effect: Set the default size, or reject this design if useful frames need too much copying.

- `fp-walk`: Does frame-pointer walking return enough useful Doris BE frames in Release builds?
  Evidence: Record Release flags. Compare returned frames with offline symbolization.
  Decision effect: Reject this design if frames are too shallow for real debugging.

- All designs: Which timeout is safe for large BE processes?
  Evidence: Compare timeout results during idle, load, allocation pressure, and jemalloc profiling.
  Decision effect: Set the default timeout, or mark timeout behavior as a blocker.

## Appendix A: Repository Model

Use one parent research repository.

The parent repository owns:

- Plan documents.
- Shared scripts.
- Test commands.
- Patch series.
- Evidence files.
- Review files.

Existing source repositories under `repos/source/` are pinned inputs.
`repos/source/doris-master` is the seed Doris checkout.

Use this Doris base commit for Phase 2:

`c24d454f15cee2d937ef4749270a3ecb449eafe6`

Use four persistent Doris worktrees under the root `phase2/` directory:

- `phase2/ck-phdr-unwind`
- `phase2/ob-kill60`
- `phase2/snapshot-remote-unwind`
- `phase2/fp-walk`

Do not add these variant worktrees as submodules.
Do not track Doris source files from these worktrees in the parent repository.
The parent repository must ignore the root `/phase2/` directory.
After creating worktrees, run `git status --short` from the parent repository.
The parent status must not show Doris source files from `phase2/`.

Track the durable work in the parent repository:

- Common patches in `patches/common/`.
- Variant patches in `patches/<variant>/`.
- Variant evidence in `evidence/phase2/variants/<variant>/`.
- Variant reviews in `reviews/<variant>.md`.

The common branch contains only shared API and shared test logic.
Each variant branch starts from the common branch.

The variant worktrees are working areas.
The patch series and evidence files are the review record.

## Appendix B: Later Goals

Online symbolization is a later goal.

The first version should return raw PCs and DSO offsets only.
Offline tools should symbolize the result.
