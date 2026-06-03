# Phase 2 Test Plan — fp-walk Baseline

> Owner: agent.
> Follow [writing-guidelines.md](writing-guidelines.md) when you edit this file.
> Scope: fp-walk only. Three tests, mirroring CK. More cases land after the
> baseline is green.
> Contract: [architecture.md](architecture.md). Gate:
> [phase2-acceptance.md](phase2-acceptance.md).

## Goal

Three tests cover the print_stack contract. Every gate command must run all
three green.

The reference is
[research/clickhouse-stack-trace-tests.md](research/clickhouse-stack-trace-tests.md).
ClickHouse uses three regression tests for `system.stack_trace`:

- a schema check (deterministic),
- a coordinator predicate check (deterministic),
- a collection check (best-effort, retried up to 100 times).

Doris mirrors the same three shapes against `/api/print_stack`.

## Test surface

Integration through real HTTP. The test process spins up an `EvHttpServer`
on port 0, registers `PrintStackAction` at `/api/print_stack`, and drives it
with `HttpClient`. The test parses the JSON body and asserts on it.

This matches the existing pattern in
`be/test/service/http/http_client_test.cpp`:

- `SetUpTestCase` constructs `EvHttpServer(0)`, registers handlers, calls
  `start()`, and records the real port.
- Tests build an `HttpClient`, point it at `http://127.0.0.1:<port>`, call
  `execute`, and read the body.
- `TearDownTestCase` deletes the server.

`print_stack_init()` runs once in `SetUpTestCase`, before any test fires, so
the signal handler and notification pipe are ready when the action runs.

## Files

- `be/test/service/http/print_stack_action_test.cpp` in `patches/common/`.
  Three `TEST_F` cases. Fixture `PrintStackActionTest`.

The test file links against fp-walk's `capture_into_slot` because that is
the only capture implementation in this phase. The build target is
`fp-walk`. Common alone is not a runnable test target.

## Mode policy

Every case runs on every mode. Case 3's retry loop absorbs TSan-induced
flakiness on the capture path. Cases 1 and 2 do not depend on captured
frames; they pass deterministically on every mode.

Reason: CK's collection regression itself is best-effort with a 100-attempt
retry. The CK reference treats asynchronous stack collection under
instrumented builds (TSan, similar) as best-effort. Doris follows the same
shape, which keeps the same case set across asan, release, and tsan.

## Cases

| # | Name | CK mirror | Setup and assertion |
| --- | --- | --- | --- |
| 1 | `ContractJsonShape` | `02117_show_create_table_system.sql` | `GET /api/print_stack`. Parse the JSON body. Required keys: root `threads`; per thread `thread_id`, `thread_name`, `trace`; per frame `dso`, `dso_offset`. No key in {`pc`, `status`, `collector`, `timeout_ms`, `max_frames`, `max_stack_bytes`, `target_tid`, `truncated`, `handler_time_ns`, `function`, `file`, `line`, `symbol`, `demangled`} appears anywhere in the body. |
| 2 | `ThreadIdSelector` | `02940_system_stacktrace_optimizations.sh` | a) `GET /api/print_stack?thread_id=<self>`. HTTP 200. `threads` has exactly one row; `thread_id == self()`. b) `GET /api/print_stack?thread_id=999999999`. HTTP 200. `threads` is empty. |
| 3 | `BestEffortFrameObserved` | `03565_system_stack_trace_works.sh` | Spawn one parked marker thread T. Loop up to 100 attempts: `GET /api/print_stack?thread_id=T`, parse the JSON body, scan `trace` for a frame whose `dso` ends in the test binary name and `dso_offset` is non-zero. Break on success. Assert that one attempt succeeded within the loop. |

## Why three

The three shapes cover what is verifiable from a unit-test binary.

- Case 1 fixes the public contract. Drift in the JSON shape fails it.
- Case 2 fixes the coordinator's selector semantics. Drift in handling
  `thread_id` (selecting only one thread; treating an absent id as empty)
  fails it.
- Case 3 fixes the capture path well enough for a baseline. A capture that
  never produces a usable frame fails it. CK's retry shape is the right
  scope for best-effort asynchronous capture.

Everything else (signal-blocked, timeout, late-handler hazards, RBP safety,
deep-stack cap) is candidate material. The baseline ships three; the rest
land when they are needed.

## Candidates

Cases to add after the gate is green.

- `SignalBlockedTreated`: a thread blocks `kServiceSignal`; the row carries
  an empty trace. Internal status stays out of JSON.
- `UnresponsiveTimeout`: a controlled non-publishing capture; the row
  carries an empty trace; a later normal dump still works. Needs a test
  hook in fp-walk's capture.
- `LateHandlerDoesNotPoison`: a late handler from one dump does not write
  into the next dump's slot. Needs a test hook.
- `DumpLoopStability`: 200-iteration loop with marker threads alive; no
  crash, no hang, workers joinable.
- `DeepStackCaps`: chain deeper than `kMaxSignalFrames` stops at the cap.
- `DsoOffsetRoundtrips`: `object.address_begin + dso_offset == captured_pc`
  via `SymbolIndex::findObject`.
- `RbpBoundsRejectsOutOfStackRBP`: drives fp-walk's `rbp_can_read`
  predicate over an accept/reject table.
- `JunkRbpDoesNotCrash`: clobbered `%rbp` plus `pause` loop; the process
  stays alive.

## The recipe

The three gate commands:

```text
just phase2-test new-ut fp-walk asan "*"
just phase2-test new-ut fp-walk release "*"
just phase2-test new-ut fp-walk tsan "*"
```

`new-ut` maps `'*'` to `*PrintStackActionTest.*`. A narrower filter passes
through. `full-ut` passes the filter directly.

Set `DORIS_BE_JOBS=<n>` to override build parallelism. Set `DORIS_BE_CLEAN=1`
only when a CI-parity clean rebuild is needed.

## Build matrix

| Mode | Flags | Build dir | What it catches |
| --- | --- | --- | --- |
| asan | `ASAN_UT`, `USE_JEMALLOC=OFF` | `ut_build_ASAN` | memory bugs in the collector itself |
| release | `RELEASE`, `USE_JEMALLOC=OFF` | `ut_build_RELEASE` | inlining drift, frame-pointer reliance under optimization, prod codegen |
| tsan | `TSAN`, `USE_JEMALLOC=OFF` | `ut_build_TSAN` | data races and lifecycle drift; capture path is best-effort under TSan |

RELEASE requires
`patches/common/0000-upstream-drop-inline-from-SegmentWriter-_is_mow-defs.patch`
applied first. `-O0` masks the issue; `-O3` exposes it as undefined-symbol
link errors against the test subclass.

`be/CMakeLists.txt` puts `-fno-omit-frame-pointer` in the global
`add_compile_options()`, so fp-walk's RBP walk works under every build type
without a patch.

## Dev workflow

Write code and tests directly in the Doris tree first; export patches once
green. Steps:

1. `just phase2-bootstrap fp-walk` to land the current `patches/` on top of
   `phase2/fp-walk`.
2. `just phase2-shell` to enter the build container at the Doris
   submodule.
3. Edit code on the `phase2/fp-walk` branch. Run BE UT inside the container
   (`bin/run-be-ut.sh --run --filter=PrintStackActionTest.*` or the
   equivalent local path).
4. Commit on `phase2/fp-walk`. For shared changes, rebase the commit onto
   `phase2/common` instead (`just phase2-rebase-all` re-bases variants
   afterwards).
5. `just phase2-export` to regenerate `patches/<scope>/`.
6. `just phase2-reset` then `just phase2-bootstrap fp-walk` to verify the
   patches re-apply.
7. Run the three gate commands.

`patches/` is the source of truth for review. Branches are reproducible
build areas.
