# snapshot-remote-unwind Review - Attempt 1

status: current-implementation-blocked

Patch reviewed:

- `patches/snapshot-remote-unwind/0001-feature-be-Add-snapshot-remote-unwind-native-stack-c.patch`

Evidence reviewed:

- `evidence/phase2/variants/snapshot-remote-unwind/`

Findings:

- Build and standalone runtime smoke passed after adapting to the installed
  libunwind headers.
- The signal handler follows the intended safety model: copy registers and
  bounded stack bytes only; no libunwind, allocation, logging, locks, or
  symbolization in the handler.
- API responses preserve the no-symbol contract.
- Patch replay against common passed.

Blocking concern:

- The installed thirdparty libunwind has `_ULx86_64_create_addr_space` as a
  null-returning stub, so true remote libunwind unwinding is unavailable in this
  build image.
- The fallback coordinator-side frame-pointer walk over the copied stack did not
  recover beyond interrupted PCs: 8KiB and 64KiB both had max depth 1 and zero
  multi-frame threads.

Review result:

- Mark the current implementation blocked, not the whole direction rejected.
- The next protocol run must first prove remote-unwinder availability, then run
  a stack-byte sweep at 8KiB, 16KiB, 32KiB, 64KiB, and 128KiB against a parked
  known-stack thread. If all depths still return only interrupted PCs, reject
  the current implementation for frame usefulness.
