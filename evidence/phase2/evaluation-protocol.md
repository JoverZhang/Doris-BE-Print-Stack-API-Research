# Phase 2 Evaluation Protocol

Status: required for the next run.

## Scope

This protocol compares Doris BE native stack collection variants. It replaces
ad hoc per-subagent judgment with shared gates.

All variants must use:

- Base commit: `c24d454f15cee2d937ef4749270a3ecb449eafe6`.
- Build image: `docker.io/apache/doris:build-env-ldb-toolchain-latest`.
- Existing downloaded and compiled thirdparty dependencies.
- The same common debug API patch and JSON contract.
- The same workload scripts, timeout settings, and evidence schema.

## Verdicts

- `pass`: every required gate passes.
- `hold`: implementation needs diagnosis, a required row is skipped, or a
  metric is ambiguous.
- `policy-fail`: the design violates an explicit production policy gate.
- `fail`: the implementation crashes, deadlocks, corrupts frames, leaves
  workers stopped, or cannot produce useful frames after the required checks.

No variant can be production-recommended while any required row is `hold`,
`skipped`, or unmeasured.

## Evidence Budget

Tracked evidence must be reviewable.

Allowed tracked files per variant:

- `manifest.yaml`
- `commands.sh`
- `verdict.md`
- one small one-TID JSON sample
- short API status samples for `busy`, `timeout`, `missing_tid`, and no-symbol
- build facts: compiler flags, linked libraries, build IDs
- concise metric CSVs and summary Markdown
- known-stack offline symbolization excerpt

Forbidden tracked files:

- full all-thread JSON responses
- full build logs
- full BE logs
- `/proc/<pid>/maps`
- duplicate patch copies under variant evidence
- raw core dumps or generated binaries

Raw artifacts belong under ignored `evidence/phase2/raw/<run-id>/<variant>/` or
`artifacts/phase2/raw/<run-id>/<variant>/`. Track only checksums and summaries
when raw files are needed for audit.

## Signal Handler Safety

Production policy gate:

- Handler-side libunwind is `policy-fail` unless a later review explicitly
  accepts a source-level async-signal-safety proof.
- Handler-side symbolization, demangling, logging, loader inspection, mutexes,
  heap allocation, `new`, `delete`, `malloc`, `free`, `dlopen`, `dlclose`,
  `dladdr`, and `dl_iterate_phdr` are `policy-fail`.

Allowed handler work must be documented and bounded:

- read interrupted registers from `ucontext_t`
- write to preallocated per-thread storage
- copy bounded stack bytes
- perform a bounded frame-pointer walk if the variant explicitly accepts that
  risk and records handler timing
- set atomic or signal-safe completion state

Every variant records handler p50/p99/max when measurable. If handler timing
cannot be measured, the reason must be stated in `verdict.md`.

## Correctness Gates

API response gates:

- all returned frames contain raw `pc`, `dso`, and `dso_offset`
- response contains no function names, source paths, line numbers, demangled
  names, or online symbol strings
- one-TID request returns only the target TID
- missing/exited TID, timeout, and concurrent dump all return explicit statuses
- non-ADMIN rejection is proven in an FE-backed auth context

Frame gates:

- every successful active worker thread has at least one non-zero PC
- at least one known-stack thread has the expected function chain after offline
  symbolization
- each sampled DSO offset resolves against the recorded DSO path and build ID
- truncated stacks are marked `truncated: true`

## Latency And Pause Gates

Default API timeout is 100 ms. Required loops:

- 100 all-thread dumps at `timeout_ms=100`
- 100 one-TID dumps at `timeout_ms=100`
- 20 all-thread dumps at `timeout_ms=1000` for diagnostic margin

Tracked metrics:

- HTTP status counts
- root status counts
- elapsed p50/p95/p99/max
- per-thread `ok`, `timeout`, `signal_blocked`, `missing`, and `error` counts
- frame depth p50/p95/max
- handler/pause p50/p99/max when measurable

A root timeout in the 100 ms loop is `hold` until root-caused. A crash,
deadlock, stuck worker, or corrupt frame is `fail`.

## Load And Churn Gates

Run the same FE/BE workload for every variant:

- continuous query workload for at least 5 minutes
- dump loop during the workload
- query success/error counts and p95 latency
- BE log excerpt containing only relevant warnings/errors

Run the same stress rows for every variant:

- jemalloc profiling disabled
- jemalloc profiling enabled
- allocation pressure during dump loop
- high-rate thread create/exit churn
- controlled `dlopen`/`dlclose` churn

Any skipped row blocks production recommendation.

## Variant-Specific Gates

`fp-walk`:

- Release compile commands must include frame-pointer retention.
- Report signal-blocked threads separately.
- Treat RBP-chain dereference in the handler as the main residual risk.

`ck-phdr-unwind`:

- If handler-side libunwind remains, verdict is `policy-fail` under this
  protocol regardless of frame quality.
- If policy is challenged, provide source audit plus DSO churn stress evidence.

`ob-kill60`:

- Timeout tails require instrumentation: signal sent, handler entered, handler
  exited, coordinator observed completion, signal-blocked, and skipped-self.
- Timeout tail alone is `hold`, not direction failure, until diagnosed.
- Handler-side libunwind remains a separate `policy-fail`.

`snapshot-remote-unwind`:

- Before BE testing, run a minimal remote-unwind capability check against the
  linked libunwind archive.
- Sweep copied stack sizes: 8KiB, 16KiB, 32KiB, 64KiB, and 128KiB.
- Use a known-stack thread with deep call depth and a parked sleep point.
- If all depths still return only interrupted PCs, mark current implementation
  `fail-for-frame-usefulness`; do not claim the whole direction is impossible.
