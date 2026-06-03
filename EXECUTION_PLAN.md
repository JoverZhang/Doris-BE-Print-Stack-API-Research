# Execution Plan — fp-walk Baseline

> Temporary file. Delete in the final commit when the gate is green.
>
> Source of truth: [docs/architecture.md](docs/architecture.md). Gate:
> [docs/phase2-acceptance.md](docs/phase2-acceptance.md). Test cases:
> [docs/phase2-test-plan.md](docs/phase2-test-plan.md).

## Decisions in scope (resolved via /grill-me)

1. Wholesale replace of `patches/common/` + `patches/fp-walk/`. No `native_stack_*` survives.
2. `DENY_ALLOCATIONS_IN_SCOPE` stays commented-out with `Reason:` + CK `Reference:` to line 121.
3. No auth in baseline. Production-deployment appendix in `architecture.md` covers it.
4. `list_target_thread_ids` validates the selector against `/proc/self/task`.
5. `constexpr int kPipeReadTimeoutMs = 100;` in `print_stack_globals.h`.
6. `print_stack_init()` is called at the end of `doris::init_signals()` in `be/src/service/doris_main.cpp`.
7. Test fixture uses `SetUpTestCase` / `TearDownTestCase` (per-fixture server + marker thread).
8. Stay on pinned base `c24d454f15cee2d937ef4749270a3ecb449eafe6`.

## Phase A — Reset the work tree

- [ ] Inspect current `patches/common/` and `patches/fp-walk/`; confirm they only hold the `native_stack_*` series.
- [ ] Delete every `*.patch` in `patches/common/` except `0000-upstream-drop-inline-from-SegmentWriter-_is_mow-defs.patch`.
- [ ] Delete every `*.patch` in `patches/fp-walk/`.
- [ ] `just phase2-reset` to drop all `phase2/*` branches in the submodule.
- [ ] `just phase2-bootstrap common` to land just the upstream link fix on `phase2/common` from the pinned base.

## Phase B — Write the common library in the Doris tree

Work on the `phase2/common` branch from inside `just phase2-shell`.

- [ ] `be/src/service/http/action/print_stack.h` — public types (`ThreadStackStatus`, `StackFrame`, `ThreadStackTrace`, `PrintStackOptions`, `PrintStackResult`, `collect_print_stack` declaration).
- [ ] `be/src/service/http/action/print_stack_globals.h` — `kServiceSignal`, `kMaxSignalFrames`, `kPipeReadTimeoutMs`, `StackCaptureSlot`, externs (`g_server_pid`, `g_sequence_num`, `g_data_ready_num`, `g_signal_latch`, `g_slot`, `g_notification_pipe_rw`), `print_stack_signal_handler`, `print_stack_init` declarations.
- [ ] `be/src/service/http/action/print_stack_capture.h` — `capture_into_slot` declaration.
- [ ] `be/src/service/http/action/print_stack_init.cpp` — definitions of the global state and `print_stack_init()`.
- [ ] `be/src/service/http/action/print_stack_signal_handler.cpp` — the handler with the commented `DENY_ALLOCATIONS_IN_SCOPE` marker.
- [ ] `be/src/service/http/action/print_stack.cpp` — coordinator: `s_dump_mutex`, `list_target_thread_ids` (with `/proc/self/task` filter), `read_thread_names`, `is_signal_blocked`, `rt_tgsigqueueinfo` wrapper, `wait_on_pipe`, `pc_to_frame` (uses `MultiVersion<SymbolIndex>::instance()`), `capture_one`, `collect_print_stack`.
- [ ] `be/src/service/http/action/print_stack_action.h` and `.cpp` — `PrintStackAction` (no privilege args), `parse_print_stack_options`, `serialize_print_stack_result` (hex-string `dso_offset`).
- [ ] Modify `be/src/service/doris_main.cpp`: append `doris::print_stack::print_stack_init();` to the end of `init_signals()` (around line 121).
- [ ] Modify `be/src/service/http_service.cpp`: register `PrintStackAction` on `GET /api/print_stack`.
- [ ] Commit on `phase2/common`. One commit per layer, or combined — reviewer-friendly granularity.

## Phase C — Write the fp-walk capture

Switch to `phase2/fp-walk` (rebased on `phase2/common`).

- [ ] `be/src/service/http/action/print_stack_fp_walk.cpp` — `capture_into_slot` definition: read RIP/RBP from `ucontext_t`, walk frames with `rbp_can_read` bounds and `mincore` page-mapped guard, write PCs into `out->pcs`, set `out->frame_count`, set `out->status = OK`.
- [ ] Commit on `phase2/fp-walk`.

## Phase D — Write the three tests

Tests live on `phase2/common`.

- [ ] `be/test/service/http/print_stack_action_test.cpp` — fixture `PrintStackActionTest` with `SetUpTestCase` opening `EvHttpServer(0)`, calling `print_stack_init()` (or relying on the production install if `main()` already ran in the test binary), registering the action, recording the real port, spawning one named parked marker thread.
- [ ] Case 1: `ContractJsonShape` — `GET /api/print_stack`; parse body; assert required keys; assert no forbidden key anywhere.
- [ ] Case 2: `ThreadIdSelector` — sub-case (a) self-tid returns one row; sub-case (b) absent tid returns empty `threads`.
- [ ] Case 3: `BestEffortFrameObserved` — loop up to 100 attempts against the marker tid; break when one frame has the test binary's `dso` and non-zero `dso_offset`; assert success.
- [ ] Manually run inside container: `cd be && bin/run-be-ut.sh --run --filter=PrintStackActionTest.*` (or local equivalent). Iterate until green under ASAN.
- [ ] Commit on `phase2/common` (or `phase2/fp-walk` if the tests must link against fp-walk; check before committing).

## Phase E — Export and verify

- [ ] `just phase2-export` to regenerate `patches/common/` and `patches/fp-walk/`.
- [ ] Inspect the generated patches; confirm filenames make sense.
- [ ] `just phase2-reset` to drop the in-tree branches.
- [ ] `just phase2-bootstrap fp-walk` to re-apply patches from scratch.
- [ ] `just phase2-test new-ut fp-walk asan "*"` — expect green. Tick the box in `docs/phase2-acceptance.md`.
- [ ] `just phase2-test new-ut fp-walk release "*"` — expect green. Tick the box.
- [ ] `just phase2-test new-ut fp-walk tsan "*"` — expect green. Tick the box.

## Phase F — Cleanup

- [ ] Append a Log entry to `docs/phase2-acceptance.md` noting the date and commit hash that landed the baseline.
- [ ] Delete `EXECUTION_PLAN.md` (this file).
- [ ] Commit the acceptance ticks + execution-plan removal.

## Things to watch for

- The pinned base has no `native_stack_*` files. If `just phase2-bootstrap` lands them anyway, the wholesale-replacement intent is being subverted somewhere; check patch list and `phase2-bootstrap.sh`.
- `print_stack_init()` must run before any test fires. If `EvHttpServer::start()` is the first thing in `SetUpTestCase`, the handler must already be installed; calling `print_stack_init()` before `EvHttpServer(0)` is the safe order.
- `MultiVersion<SymbolIndex>::instance()` is lazy; first call inside the coordinator constructs it. Don't call it from the handler.
- `kPipeReadTimeoutMs = 100` × 100 retries in case 3 = ~10 seconds worst case. TSan will be slow; allow generous gtest test-timeout.
- Tests sit in `patches/common/` per the acceptance doc. They will only compile as part of the `fp-walk` build because they need `capture_into_slot` linked; running `just phase2-test new-ut common ...` will fail at link time — expected.
