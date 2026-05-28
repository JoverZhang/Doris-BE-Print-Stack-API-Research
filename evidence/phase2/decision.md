# Phase 2 Decision

Selected result: `fp-walk` as the next design to harden.

Final production approval: no.

Reason for selection:

- `fp-walk` is the only variant that returned useful multi-frame Doris stacks
  while avoiding libunwind work in the signal handler.
- It built and ran in the requested Doris build image.
- It returned raw PCs and DSO offsets only.
- It produced offline-symbolizable frames, including the native stack API path.
- It completed 50 repeated all-thread dumps with no timeout, crash, or deadlock
  in this standalone BE run.

Evidence:

- Patch: `patches/fp-walk/0001-feature-be-Add-fp-walk-native-stack-collector.patch`
- Evidence: `evidence/phase2/variants/fp-walk/`
- Review: `reviews/fp-walk.md`

Rejected variants:

- `ck-phdr-unwind`: rejects on signal-handler safety. It is buildable and
  returns good frames, but it runs libunwind in interrupted worker signal
  handlers. PHDR preflight and global libunwind cache do not prove this is safe.
- `ob-kill60`: rejects on signal-handler safety and timeout predictability. It
  also uses libunwind in the handler, and 1000 ms all-thread repeats had a
  timeout tail.
- `snapshot-remote-unwind`: rejects on frame usefulness with the current build
  image. The handler model is safest, but the installed libunwind remote address
  space creator is stubbed, and the fallback recovered only interrupted PCs.

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

Harden `fp-walk` under the missing matrix rows. If frame-pointer dereference risk
is unacceptable, revisit `snapshot-remote-unwind` only after Doris can link a
real remote unwinder or provide a coordinator-side DWARF/EH-frame unwinder over
copied stack bytes.
