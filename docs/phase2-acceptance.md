# Phase 2 Baseline Acceptance — fp-walk

> Owner: human for the Gate; agent updates the work checklist as patches land.
> Follow [writing-guidelines.md](writing-guidelines.md) when you edit this file.
> Scope: fp-walk only. The other three variants stay frozen this phase.
> Append-only. Tick boxes as work lands. Add notes below. Do not delete past
> entries.

## Gate

The baseline is accepted when all three commands return green from the base
commit `c24d454f15cee2d937ef4749270a3ecb449eafe6`:

- [ ] `just phase2-test new-ut fp-walk asan "*"`
- [ ] `just phase2-test new-ut fp-walk release "*"`
- [ ] `just phase2-test new-ut fp-walk tsan "*"`

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

### patches/common/

- [ ] `0001-be-add-print-stack-types-and-process-startup.patch`
      Layer 1. `print_stack.h`, `print_stack_globals.h`,
      `print_stack_init.cpp`. `main()` calls `print_stack_init()`.
- [ ] `0002-be-add-print-stack-coordinator-and-handler.patch`
      Layer 3 + 4. `print_stack.cpp`, `print_stack_signal_handler.cpp`,
      `print_stack_capture.h` (declaration only).
- [ ] `0003-be-add-print-stack-http-action.patch`
      Layer 2 + 5. `print_stack_action.{h,cpp}`.
- [ ] `0004-be-register-print-stack-http-route.patch`
      Route `/api/print_stack`.
- [ ] `0005-be-add-print-stack-action-tests.patch`
      Three cases per [phase2-test-plan.md](phase2-test-plan.md). Fixture
      runs `EvHttpServer` on port 0 and uses `HttpClient`.

### patches/fp-walk/

- [ ] `0001-be-add-fp-walk-capture-into-slot.patch`
      Layer 3d. `capture_into_slot` definition. Signal-safe RBP walk.
      `mincore` guard.

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
