# Doris BE Stack Collection Charter

> Owner: human. Frozen spec.
> Agents must not edit this file. If it seems wrong, stop and report.
> This file holds the goal and the constraints. Gates live in
> [phase2-acceptance.md](phase2-acceptance.md). Mechanics live in
> [phase2-design.md](phase2-design.md).

## Goal

Choose one design to collect live native stacks from `doris_be`.

This phase compares four designs under one debug API, one base commit, and one
acceptance bar. The output is one selected design, or `none`.

This phase does not produce the production PR.
This phase does not include online symbolization.
This phase does not verify signal-handler async-signal-safety. That review moves
to the phase that evaluates the libunwind variants.

## Current Focus

Prove `fp-walk` first, as the baseline.

- Carry `fp-walk` through the acceptance bar before testing other designs.
- The baseline sets the reference numbers and proves the test harness.
- Compare the other three designs only after the baseline passes.

## Decision

Answer one question:

Which design should Doris use to collect live BE native stacks?

The decision record must give:

- The selected design, or `none`.
- The reason for the selection.
- The reason each other design was rejected.
- The evidence path for each design.
- The risks that remain.

## Variants

- `fp-walk`: walk the RIP/RBP frame chain in the signal handler. Needs frame
  pointers in the Release build.
- `ck-phdr-unwind`: run libunwind in the signal handler, with a ClickHouse-style
  PHDR cache.
- `ob-kill60`: collect in the signal handler, OceanBase-style with a
  single-phase ack — the handler captures and returns, the coordinator
  resolves DSO offsets after the handler exits. OceanBase's two-phase ack
  (worker pauses for coordinator) is the reference, not the variant we test.
- `snapshot-remote-unwind`: copy registers and bounded stack bytes in the
  handler; the coordinator unwinds from the snapshot.

## Hard Constraints

The debug API is the same for every variant.

- Route: `GET /api/debug/native_stack`.
- Returns raw PCs and DSO offsets only.
- Returns no function names, file names, line numbers, or demangled names.
- Supports all threads by default, or one thread by TID.
- Allows one active dump at a time. A second request waits up to its
  `timeout_ms` for the active dump to finish. If it cannot start in time, it
  returns `timeout`.
- Targets Linux x86_64 Release builds.

Defaults: timeout `100ms`, max frames `64`, max copied stack bytes `8KiB`.

`timeout_ms` is the budget for the whole request, not for one thread. Collection
is sequential, so an all-thread dump may not reach every thread inside the
budget. The dump returns best effort: it reports the threads it collected, marks
the rest `timeout`, and keeps the process healthy. One slow thread does not fail
the whole dump.

For each frame, `dso_offset` is the value offline tools resolve. The raw `pc` is
a runtime address for in-process correlation only; it does not survive across
runs.

Only offline tools may add symbols, file names, and line numbers.

## Repository Model

- One parent research repository owns plans, patches, evidence, and reviews.
- `patches/` is the source of truth. `patches/common/` holds the shared API and
  shared tests. `patches/<variant>/` holds one variant.
- `phase2/<variant>` worktrees are reproducible build areas, not tracked source.
- Base commit: `c24d454f15cee2d937ef4749270a3ecb449eafe6`.

See [AGENTS.md](../AGENTS.md) for the patch-first workflow.

## Related Documents

- [phase2-acceptance.md](phase2-acceptance.md): pass/fail gates. Human-owned.
- [phase2-design.md](phase2-design.md): API and variant mechanics. Agent-owned.
- [writing-guidelines.md](writing-guidelines.md): house style for these docs.
- [../evidence/phase2/subagent-brief-template.md](../evidence/phase2/subagent-brief-template.md):
  per-variant dispatch brief. Agent-owned.
