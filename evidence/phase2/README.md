# Phase 2 Evidence

Base Doris commit: `c24d454f15cee2d937ef4749270a3ecb449eafe6`.

Build image: `docker.io/apache/doris:build-env-ldb-toolchain-latest`; see `shared/docker-image.txt`.

This directory is now a reviewable summary package. Full all-thread JSON dumps,
complete build logs, `/proc/<pid>/maps`, runtime log tails, and duplicate patch
copies were removed from the tracked evidence after the first attempt produced a
249k-line review diff. Raw artifacts for future runs belong under ignored
`evidence/phase2/raw/` or `artifacts/phase2/raw/`, with short summaries tracked
here.

Protocol for the next run:

- `evaluation-protocol.md`: pass/fail/hold gates and evidence budget.
- `subagent-brief-template.md`: standard brief for future variant workers.
- `next-round.md`: recommended execution order.

Patch-first workflow:

- Edit `patches/common/*.patch` or `patches/<variant>/*.patch` first.
- Run `just phase2-apply <variant>` to regenerate `phase2/<variant>` from the
  patch series.
- Run `just phase2-diff <variant>` only to inspect temporary worktree edits.
- Run `just phase2-export <variant>` only when intentionally converting
  committed worktree changes back into patch files.
- Apply/export scripts preserve ignored build/cache directories; they reset only
  tracked files after refusing tracked dirty state.

## Shared Common API

Patch series:

- `patches/common/0001-feature-be-Add-native-stack-debug-API-stub.patch`

Key evidence:

- `shared/common-api-ninja-doris_be.txt`: successful `doris_be` target verification inside the Doris build image.
- `shared/be-startup-key.txt`: BE started from `be/output` in Docker with HTTP port 8040 mapped to host 18040.
- `shared/api-smoke/*.json`: API smoke results for `ok`, `missing_tid`, `timeout`, `busy`, and `bad_request`.

Runtime smoke used `be/output/conf/be.conf` with `enable_java_support = false`, because the common build explicitly disabled BE Java extensions and CDC client to avoid Maven dependency builds.

## Variant Results

Patch replay from base plus common passed for all four variants; see
`patch-check.txt`.

Current decision:

- Carry `fp-walk` forward as the next design to harden.
- Do not mark it production-approved yet; FE auth, query workload, allocation
  pressure, and churn rows remain open.

Variant summaries:

- `fp-walk`: lead candidate. Useful multi-frame stacks, no libunwind in signal
  handler, 50 repeated all-thread dumps passed.
- `ck-phdr-unwind`: exploration pass for frame quality, production policy fail
  if handler-side libunwind is forbidden.
- `ob-kill60`: exploration hold. Handler-side libunwind hits the same policy
  gate; the timeout tail also needs root-cause instrumentation before it can be
  called an implementation bug or a directional problem.
- `snapshot-remote-unwind`: current implementation blocked. Handler model is
  strongest, but the installed remote libunwind path is stubbed; stack-depth and
  unwinder-availability checks must be rerun before rejecting the direction.

Final comparison and decision files:

- `reviews/final-comparison.md`
- `evidence/phase2/decision.md`
