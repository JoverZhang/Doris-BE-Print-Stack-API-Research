# Phase 2 Test Plan — fp-walk Baseline

> Owner: agent.
> Follow [writing-guidelines.md](writing-guidelines.md) when you edit this file.
> Scope: fp-walk only. Three cases, mirroring CK.
> Contract: [architecture.md](architecture.md). Gate:
> [phase2-acceptance.md](phase2-acceptance.md).

## Goal

Three cases cover the print_stack contract. The reference is
[research/clickhouse-stack-trace-tests.md](research/clickhouse-stack-trace-tests.md);
CK uses three regression tests for `system.stack_trace` (schema, coordinator,
collection) and Doris mirrors the same shapes against `/api/print_stack`.

## Cases

| # | Name | CK mirror | Setup and assertion |
| --- | --- | --- | --- |
| 1 | `ContractJsonShape` | `02117_show_create_table_system.sql` | `GET /api/print_stack`. Parse the JSON body. Required keys: root `threads`; per thread `thread_id`, `thread_name`, `trace`; per frame `dso`, `dso_offset`. No key in {`pc`, `status`, `collector`, `timeout_ms`, `max_frames`, `target_tid`, `truncated`, `function`, `file`, `line`, `symbol`, `demangled`} appears anywhere. |
| 2 | `ThreadIdSelector` | `02940_system_stacktrace_optimizations.sh` | a) `GET /api/print_stack?thread_id=<self>`. HTTP 200. `threads` has exactly one row with the requested `thread_id`. b) `GET /api/print_stack?thread_id=999999999`. HTTP 200. `threads` is empty. |
| 3 | `BestEffortFrameObserved` | `03565_system_stack_trace_works.sh` | Spawn one parked marker thread T. Loop up to 100 attempts: `GET /api/print_stack?thread_id=T`, parse the JSON body, scan `trace` for a frame whose `dso` ends in the test binary name and `dso_offset` is non-zero. Break on success. Assert one attempt succeeded. |

## Mode policy

Every case runs on every mode (`asan`, `release`, `tsan`). Cases 1 and 2 are
deterministic. Case 3 is best-effort by design; the retry loop absorbs
TSan-induced flakiness on the capture path. This mirrors CK's collection
regression, which also retries up to 100 times.

## Test surface

Integration through real HTTP. The test process spins up an `EvHttpServer`
on port 0, registers `PrintStackAction` at `/api/print_stack`, and drives
it with `HttpClient`. The fixture follows
`be/test/service/http/http_client_test.cpp`:

- `SetUpTestCase` constructs `EvHttpServer(0)`, registers the action, calls
  `start()`, records the real port, and calls `print_stack_init()` once.
- Tests build `HttpClient` against `http://127.0.0.1:<port>` and read the
  response body.
- `TearDownTestCase` deletes the server.

## Files

`be/test/service/http/print_stack_action_test.cpp` in `patches/common/`.
Fixture `PrintStackActionTest`. The build target is `fp-walk`, which links
fp-walk's `capture_into_slot`.

## Build matrix

| Mode | Flags | Build dir | What it catches |
| --- | --- | --- | --- |
| asan | `ASAN_UT`, `USE_JEMALLOC=OFF` | `ut_build_ASAN` | memory bugs in the collector |
| release | `RELEASE`, `USE_JEMALLOC=OFF` | `ut_build_RELEASE` | inlining drift, prod codegen |
| tsan | `TSAN`, `USE_JEMALLOC=OFF` | `ut_build_TSAN` | data races; capture is best-effort under TSan |

RELEASE requires
`patches/common/0000-upstream-drop-inline-from-SegmentWriter-_is_mow-defs.patch`
applied first. `be/CMakeLists.txt` already passes
`-fno-omit-frame-pointer` globally, so fp-walk works under every mode
without a build patch.

## Dev workflow

Write code and tests directly in the Doris tree; export patches once green:

1. `just phase2-bootstrap fp-walk` to land current `patches/` on
   `phase2/fp-walk`.
2. `just phase2-shell` to enter the build container.
3. Edit on `phase2/fp-walk` (or `phase2/common` for shared code). Run BE UT
   manually inside the container.
4. Commit on the right branch.
5. `just phase2-export` to regenerate `patches/`.
6. `just phase2-reset` then `just phase2-bootstrap fp-walk` to confirm a
   clean re-apply.
7. Run the three gate commands.

`patches/` is the source of truth for review.
