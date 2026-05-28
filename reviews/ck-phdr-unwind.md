# ck-phdr-unwind Review - Attempt 1

status: policy-fail-if-handler-libunwind-forbidden

Patch reviewed:

- `patches/ck-phdr-unwind/0001-feature-be-Add-ck-phdr-unwind-native-stack-collector.patch`

Evidence reviewed:

- `evidence/phase2/variants/ck-phdr-unwind/`

Findings:

- Build and runtime smoke passed. `doris_be` linked and the final `build.sh`
  failure is the known bind-mount `cp -p` packaging issue.
- API contract passed: raw `pc`, `dso`, and `dso_offset`, with no online
  symbol fields.
- Repeat was stable in this run: 50/50 dumps returned `status=ok`.
- Offline symbolization resolved Doris frames, including
  `NativeStackAction::handle`.
- Initial link failure exposed that the shipped libunwind archive provides
  local-only `_ULx86_64_*` symbols; defining `UNW_LOCAL_ONLY` fixed this.

Blocking concern:

- The collector runs libunwind in the worker signal handler. The PHDR preflight
  and `UNW_CACHE_GLOBAL` reduce lazy-cache risk, but they do not prove libunwind
  is async-signal-safe or cannot allocate/take locks for unseen PCs.

Review result:

- Under `evaluation-protocol.md`, handler-side libunwind is a production
  `policy-fail`; the variant can still be used as frame-quality evidence.
- If this policy is challenged, the missing proof must be source-level and
  stress-based. Repeating that it "did not fail" in smoke tests is not enough.
