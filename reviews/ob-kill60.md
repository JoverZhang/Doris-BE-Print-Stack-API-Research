# ob-kill60 Review - Attempt 1

status: hold-plus-policy-issue

Patch reviewed:

- `patches/ob-kill60/0001-feature-be-Add-ob-kill60-native-stack-collector.patch`

Evidence reviewed:

- `evidence/phase2/variants/ob-kill60/`

Findings:

- Build and standalone runtime smoke passed. `build.sh` reached BE link/install
  and then hit the known bind-mount packaging copy issue.
- API contract passed for all-thread, one-TID, busy, timeout, and missing-TID
  smoke cases.
- No online symbol fields were returned.
- Offline symbolization of DSO offsets worked.
- The 5000 ms all-thread sample returned `status=ok`, but the 1000 ms repeat
  loop alternated between `ok` and `timeout`: 27 ok, 23 timeout over 50 runs.

Blocking concerns and holds:

- The implementation still uses libunwind inside the signal handler to collect
  PCs, so it carries the same async-signal-safety issue as `ck-phdr-unwind`.
- Timeout behavior is less predictable than `fp-walk` and `ck-phdr-unwind` in
  the 1000 ms repeat loop, but the evidence does not prove why. It might be a
  fixable implementation issue, a coordinator wait bug, signal-blocked threads,
  or handler-side libunwind latency.
- The coordinator skips the request thread in this control flow, which weakens
  the known-stack evidence for the HTTP handler itself.

Review result:

- Under `evaluation-protocol.md`, handler-side libunwind is a production
  `policy-fail`.
- Treat the timeout tail as `hold` until instrumentation separates signal sent,
  handler entered, handler exited, coordinator observed completion,
  signal-blocked, and skipped-self cases.
