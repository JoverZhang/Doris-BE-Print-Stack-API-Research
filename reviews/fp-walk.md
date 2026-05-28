# fp-walk Review - Attempt 1

status: lead-candidate-not-production-pass

Patch reviewed:

- `patches/fp-walk/0001-feature-be-Add-fp-walk-native-stack-collector.patch`

Evidence reviewed:

- Build: `evidence/phase2/variants/fp-walk/build-output/`
- API: `evidence/phase2/variants/fp-walk/api/`
- Correctness: `evidence/phase2/variants/fp-walk/correctness/`
- Repeat: `evidence/phase2/variants/fp-walk/repeat/`
- Jemalloc: `evidence/phase2/variants/fp-walk/jemalloc/`

Findings:

- The collector keeps symbolization and DSO offset resolution out of the signal
  handler. Handler work is bounded by `max_frames` and `max_stack_bytes`.
- The signal handler still dereferences the interrupted thread's RBP chain. This
  is the core fp-walk risk; evidence shows it worked in this standalone BE run,
  but the design remains less robust than a pure snapshot-copy handler.
- Four BE threads blocked the collector signal. The variant reports them as
  `signal_blocked`, which avoids false request-level timeouts but means all
  threads are not equally observable.
- Permission rejection was not proven in standalone BE mode; the route is
  registered with ADMIN in common API, but this evidence run has no FE auth
  context.

Review result:

- Accept as the pilot baseline for launching the remaining variants.
- Do not treat as final `pass` for decision until query workload, allocation
  pressure, permission, and churn rows are completed or explicitly accepted as
  gaps.
- Under `evaluation-protocol.md`, this is the first candidate to rerun through
  the full matrix after the shared harness is calibrated.
