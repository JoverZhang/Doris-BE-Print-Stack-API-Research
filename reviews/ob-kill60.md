# ob-kill60 Review

status: fail-for-production-safety

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

Blocking concerns:

- The implementation still uses libunwind inside the signal handler to collect
  PCs, so it carries the same async-signal-safety issue as `ck-phdr-unwind`.
- Timeout behavior is less predictable than `fp-walk` and `ck-phdr-unwind` in
  the 1000 ms repeat loop.
- The coordinator skips the request thread in this control flow, which weakens
  the known-stack evidence for the HTTP handler itself.

Review result:

- Reject as a production direction. It is useful exploration evidence for the
  two-phase flow, but the handler risk and timeout tail are worse than the
  fp-walk candidate.
