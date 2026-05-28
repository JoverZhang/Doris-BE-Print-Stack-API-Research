# Phase 2 Attempt 1 Decision

Status: exploratory decision, not production recommendation.

Selected next hardening candidate: `fp-walk`.

Reason for selection:

- `fp-walk` is the only variant that returned useful multi-frame Doris stacks
  while avoiding libunwind work in the signal handler.
- It built and ran in the requested Doris build image.
- It returned raw PCs and DSO offsets only.
- It produced offline-symbolizable frames, including the native stack API path.
- It completed 50 repeated all-thread dumps with no timeout, crash, or deadlock
  in this standalone BE run.

Why this is not enough:

- The first evidence package mixed raw logs, raw all-thread JSON, build noise,
  and summaries, so it was not reviewable.
- The variants did not run through a uniform full matrix.
- The rejected-variant language overreached in places. Timeout tails and
  snapshot frame depth need root-cause gates, not loose narrative judgment.
- A skipped required row still blocks a production recommendation.

Evidence:

- Patch: `patches/fp-walk/0001-feature-be-Add-fp-walk-native-stack-collector.patch`
- Evidence: `evidence/phase2/variants/fp-walk/`
- Review: `reviews/fp-walk.md`

Current classification of other variants:

- `ck-phdr-unwind`: frame quality is good. It fails the proposed production
  safety policy if handler-side libunwind is forbidden. Without that policy, it
  needs source-level and stress evidence proving libunwind cannot allocate,
  lock, touch loader state, or otherwise violate signal-handler constraints.
- `ob-kill60`: same handler-side libunwind policy issue. The 1000 ms timeout
  tail is a HOLD item, not a proven direction failure, until instrumentation
  separates signal delivery, handler entry/exit, signal-blocked threads,
  coordinator waiting, and skipped request-thread behavior.
- `snapshot-remote-unwind`: current implementation is blocked by the installed
  thirdparty libunwind remote address-space stub. The direction remains open if
  a real remote unwinder is linked or if a coordinator-side snapshot unwinder
  can recover useful multi-frame stacks. Stack-byte depth alone was only checked
  at 8KiB and 64KiB in an idle standalone BE and must be rerun under a standard
  stack-depth sweep before making a stronger claim.

Remaining risks for `fp-walk`:

- It dereferences the interrupted thread's frame-pointer chain in the signal
  handler. The walk is bounded, but this remains the main safety risk.
- Threads that block the collector signal are reported as `signal_blocked`; they
  are not observable by this endpoint.
- Standalone BE smoke did not prove FE-backed ADMIN rejection.
- Query workload, allocation pressure, controlled `dlopen`/`dlclose`, and
  high-rate thread churn remain required before a final production recommendation.
- The repeat evidence used standalone BE, not a full FE/BE query workload.

Next step:

Use `evaluation-protocol.md` and `subagent-brief-template.md` for the next
round. First cleanly rerun the harness on one calibration variant, then rerun
`fp-walk` and any still-interesting alternatives under the same matrix.
