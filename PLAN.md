# Doris BE Stack Collection Plan

## Goal

Choose one stack collection design for Doris BE.

This phase must produce evidence from Doris itself.
It must compare four designs under the same API, the same base commit, and the same test matrix.

This phase does not need to produce the final production PR.
This phase does not include online symbolization.

## Decision

Answer one question:

Which design should Doris use to collect live BE native stacks?

The decision must cover:

- Safety in signal handlers.
- Correctness of collected PCs.
- Latency during stack dump.
- Behavior under load.
- Behavior with jemalloc profiling.
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

## Acceptance Criteria

A variant passes basic acceptance when it can:

- Build `doris_be`.
- Start a local BE.
- Return stack dump JSON from the debug API.
- Return at least one valid frame for active worker threads.
- Produce PC values that offline tools can symbolize.
- Respect timeout limits.
- Avoid blocking workers after the dump finishes.
- Avoid crashes during repeated stack dumps.

A variant fails when it:

- Deadlocks Doris.
- Crashes Doris.
- Leaves workers blocked.
- Corrupts stack data.
- Needs unsafe global state without a clear guard.
- Cannot work with jemalloc profiling enabled.

## Test Matrix

Run the same tests for every variant.

Build tests:

- Build Doris Release.
- Record compiler flags.
- Record jemalloc profiling settings.
- Record linked unwind libraries.

Functional tests:

- Dump all threads.
- Dump one target TID.
- Trigger two dumps at the same time.
- Trigger repeated dumps in a loop.
- Symbolize returned PCs offline.

Load tests:

- Run a query workload.
- Trigger stack dump during the workload.
- Measure API latency.
- Measure worker pause time when possible.
- Check query errors and BE logs.

Risk tests:

- Enable jemalloc profiling.
- Disable jemalloc profiling.
- Load and unload shared libraries if possible.
- Trigger stack dump during memory allocation pressure.
- Trigger stack dump during thread creation and exit.

## Evidence

Each variant must produce:

- Patch series.
- Build log.
- API response sample.
- Offline symbolization result.
- Repeated dump result.
- Load test result.
- jemalloc profiling result.
- Known risks.
- Final verdict.

Use the same evidence layout for every variant.

## Decision Rule

Prefer the design that:

- Passes the full test matrix.
- Has the smallest signal-handler risk.
- Has predictable timeout behavior.
- Needs the least invasive Doris change.
- Works with jemalloc profiling.
- Produces enough frames for debugging real BE problems.

Reject a design when its core risk cannot be reduced inside Doris.

## Open Questions

Resolve these questions during the experiments:

- Does `ob-kill60` really need to block workers during symbol processing?
- Can PHDR cache updates stay correct across Doris shared library behavior?
- Is frame-pointer walking enough for real Doris debugging?
- How much stack memory should `snapshot-remote-unwind` copy by default?
- Which timeout value is safe for large BE processes?

## Appendix A: Repository Model

Use one parent research repository.

The parent repository owns:

- Plan documents.
- Shared scripts.
- Test commands.
- Result files.
- Patch series for each variant.

Use four persistent Doris worktrees:

- `phase2/ck-phdr-unwind`
- `phase2/ob-kill60`
- `phase2/snapshot-remote-unwind`
- `phase2/fp-walk`

Use the same Doris base commit for every worktree:

`c24d454f15cee2d937ef4749270a3ecb449eafe6`

Do not use submodules for the Doris worktrees.
Track the variant patches from the parent repository.

## Appendix B: Later Goals

Online symbolization is a later goal.

The first version should return raw PCs and DSO offsets only.
Offline tools should symbolize the result.
