# Doris BE Stack Collection Acceptance

> Owner: human. Frozen spec.
> Agents must not edit this file. If it seems wrong, stop and report.

## Rule

A variant is accepted when a command proves it, not when a document describes it.

The baseline gate is one command. It runs from the base commit, applies the
patches, builds `doris_be`, and runs the variant tests. A green run is the only
proof that counts.

A variant without a `tests-` patch in `patches/common/` cannot pass.

## Tiers

Acceptance has two tiers this phase. Both are commands. The baseline is Tier 1
alone.

- Tier 1: correctness. Fast in-process tests. This is the baseline gate.
- Tier 2: compatibility. The same tests under jemalloc profiling and
  address-space churn. Required before any production claim.

Handler async-signal-safety is deferred to the next phase. See "Deferred to the
next phase" below.

## Tier 1: Correctness (Baseline Gate)

Run one command. Example: `just phase2-test new-ut <variant> asan '*'`.

It must:

1. Apply `patches/common/*` and `patches/<variant>/*` from the base commit.
2. Build `doris_be` and the test target.
3. Run `be/test/service/http/print_stack_action_test`.

The test binary spawns its own known-stack threads and dumps itself. It needs no
FE, no cluster, and no Docker runtime.

Contract checks:

- All-thread dump returns the agreed JSON shape: root `threads`; per thread
  `thread_id`, `thread_name`, and `trace`; per frame `dso` and `dso_offset`.
- One-`thread_id` dump returns only the target thread.
- Two concurrent dumps serialize: the second blocks until the first
  completes; neither corrupts the other. Contention is not visible in the
  public response.
- Each thread has a bounded wait. A thread that does not respond within the
  bound carries internal `ThreadStackStatus::Timeout`; its public `trace` is
  empty. The process stays healthy.
- An absent `thread_id` returns an empty `threads` array.
- Every frame has `dso` and `dso_offset` only.
- No response has a function name, file name, line number, raw PC, or
  demangled name.

Correctness checks, in-process:

- Each active spawned thread returns at least one frame with non-empty `dso`
  and non-zero `dso_offset`.
- A known-stack thread returns the expected function chain after offline
  symbolization against the test binary.
- A stack deeper than `kMaxSignalFrames` is capped at the slot's frame array
  length. The cap is an internal contract; the public JSON has no `truncated`
  field.

Stability check:

- A dump loop of N iterations causes no crash, no deadlock, and no stuck thread.
- A thread that runs the handler after the deadline does not corrupt a later
  dump. The stale response is dropped.

## Tier 2: Compatibility

Run the same kind of test under the conditions that break these designs.
Scripted and replayable. One process or one BE. No cluster, no FE. Not part of
the baseline.

The shared risk is the allocator. Doris BE runs jemalloc. With profiling on,
allocation paths hold internal locks and take their own backtraces through
`dl_iterate_phdr`. A handler that also unwinds can deadlock against that path.
This tier proves a variant survives it. The design doc explains the mechanism.

Required gates. A variant cannot be production-recommended if one fails:

- jemalloc profiling on, then off. The key gate. The collector must survive a
  dump loop with profiling on. The variants that unwind in the handler carry the
  risk and must show their mitigation works. `fp-walk` uses no libunwind, so it
  should pass without one.
- Allocation pressure during the dump loop.
- High-rate thread create and exit churn.
- Controlled `dlopen` and `dlclose` churn.

## Deferred to the next phase

Handler async-signal-safety. The handler must not allocate memory, take locks,
call libunwind, call symbolization, log, or inspect the loader.

This cannot be a green test. A passing test proves good behavior on the paths it
ran. It says nothing about a path it did not run. The proof is code review
against the list above, plus a TSan or ASan run of the dump loop.

The risk lives in the variants that unwind in the handler, which this phase does
not evaluate. `fp-walk` does none of those operations, so its handler is
low-risk. The review moves to the phase that evaluates the libunwind variants.

## Verdicts

- `baseline-pass`: Tier 1 is green.
- `production-pass`: Tier 1 and Tier 2 are green.
- `hold`: a required check is skipped, flaky, or unmeasured.
- `fail`: a crash, deadlock, stuck worker, corrupt frame, or no useful frames.

A skipped Tier 1 check, or a skipped required Tier 2 gate, blocks the production
claim. `production-pass` is this phase's bar. A real production ship also needs
the deferred async-signal-safety review.

---

These docs follow [writing-guidelines.md](writing-guidelines.md).
