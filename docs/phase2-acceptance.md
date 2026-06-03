# Phase 2 Baseline Acceptance — fp-walk

> Owner: human for the Gate; agent updates the work checklist as patches land.
> Follow [writing-guidelines.md](writing-guidelines.md) when you edit this file.
> Scope: fp-walk only. The other three variants stay frozen this phase.
> Append-only. Tick boxes as work lands. Add notes below. Do not delete past
> entries.

## Gate

The baseline is accepted when all three commands return green from the base
commit `c24d454f15cee2d937ef4749270a3ecb449eafe6`:

- [x] `just phase2-test new-ut fp-walk asan "*"`
- [x] `just phase2-test new-ut fp-walk release "*"`
- [x] `just phase2-test new-ut fp-walk tsan "*"`

The three cases that must run green are defined in
[phase2-test-plan.md](phase2-test-plan.md).

## Work to reach the gate

Other variants (`ck-phdr-unwind`, `ob-kill60`, `snapshot-remote-unwind`) are
out of scope. Their existing patches stay frozen.

The new `patches/common/` and `patches/fp-walk/` series is a wholesale
replacement. The existing `native_stack_*` patches in those directories
get deleted; the new series below takes their place. The pinned base
commit `c24d454f15cee2d937ef4749270a3ecb449eafe6` has no `native_stack_*`
or `print_stack_*` files, so the new series creates `print_stack_*` files
in their place and registers only `/api/print_stack`.

The patch series follows the layers in [architecture.md](architecture.md).
One patch per logical change; split or merge as needed for review.

`patches/common/0000-upstream-drop-inline-from-SegmentWriter-_is_mow-defs.patch`
is the upstream link fix needed for RELEASE. Already present; no rewrite.

The series shipped landed bundled rather than split per the planned
1-patch-per-layer breakdown — small enough that one commit per branch
is easier to review than five tiny ones. The result is identical at
the file level; only the commit granularity differs.

### patches/common/

- [x] `0001-phase2-common-add-print_stack-types-coordinator-acti.patch`
      Layers 1 + 2 + 3 + 4 + 5. `print_stack.h`, `print_stack_globals.h`,
      `print_stack_capture.h`, `print_stack_init.cpp`,
      `print_stack_signal_handler.cpp`, `print_stack.cpp`,
      `print_stack_action.{h,cpp}`. `init_signals()` calls
      `print_stack_init()`. Route `/api/print_stack` registered in
      `http_service.cpp`.
- [x] `0002-phase2-common-add-print_stack-action-tests-3-cases.patch`
      Three cases per [phase2-test-plan.md](phase2-test-plan.md). Fixture
      runs `EvHttpServer` on port 0 and uses `HttpClient`.

### patches/fp-walk/

- [x] `0001-phase2-fp-walk-add-capture_into_slot-RBP-chain-walke.patch`
      Layer 3d. `capture_into_slot` definition. Signal-safe RBP walk.
      `mincore` guard.
- [x] `0002-phase2-fp-walk-allow-first-iteration-RBP-and-bound-m.patch`
      Bug-fix follow-up: the original bound rejected the initial
      `rbp == first_rbp`, which dropped the chain to one frame. Allow
      equality on the first iteration; bound monotonic growth.

## Dev workflow

The recommended flow when implementing the patches above:

1. `just phase2-bootstrap fp-walk` to land the current `patches/` on
   `phase2/fp-walk`.
2. `just phase2-shell` to enter the build container.
3. Edit code on the `phase2/fp-walk` branch (or `phase2/common` for shared
   code). Run BE UT manually inside the container.
4. Commit on the right branch.
5. `just phase2-export` to regenerate `patches/`.
6. `just phase2-reset` then `just phase2-bootstrap fp-walk` to confirm the
   patches re-apply on a clean tree.
7. Run the three gate commands.

`patches/` is the source of truth for review.

## References

Implementer entry points into the upstream sources:

- [`.mira/steps/clickhouse-system-stack-trace.mira.step`](../.mira/steps/clickhouse-system-stack-trace.mira.step):
  trace of the ClickHouse `system.stack_trace` path. Use it to find the
  layer-3 protocol code paths cited in `architecture.md` Reference lines.
- [`.mira/steps/oceanbase-kill60-stack-trace.mira.step`](../.mira/steps/oceanbase-kill60-stack-trace.mira.step):
  trace of the OceanBase kill-60 collection path. Background only; OB is
  not in baseline scope.

The Doris HTTP integration test pattern to copy is
`be/test/service/http/http_client_test.cpp` (real `EvHttpServer` +
`HttpClient`).

## Log

Append progress, blockers, and decisions below. Do not delete past entries.

- 2026-06-04: file created. Prior spec is in `archive/phase2-spec/`. The
  contract is `architecture.md`. Test scope is three CK-shape cases. No
  patches rewritten yet.
- 2026-06-04: baseline accepted. All three gate commands green from base
  `c24d454f15c` with submodule `phase2/fp-walk` at `7b7a3dbcd44d`. The
  series wholesale-replaced the prior `native_stack_*` patches in
  `patches/common/` and `patches/fp-walk/`. Other variants
  (`ck-phdr-unwind`, `ob-kill60`, `snapshot-remote-unwind`) stay frozen
  and broken-on-bootstrap, as planned.
