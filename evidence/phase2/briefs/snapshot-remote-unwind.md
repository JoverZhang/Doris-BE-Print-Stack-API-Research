# Brief: snapshot-remote-unwind (Round 2, variant 2)

Third and final variant of the libunwind-class round. This is the one
whose handler runs no libunwind at all — it copies registers and
bounded stack bytes into the slot, and the coordinator unwinds from
the snapshot using libunwind's remote API.

**Pre-verify gate first.** The prior phase found that the linked
thirdparty libunwind archive stubbed remote address-space creation.
Before any handler work, prove the remote API resolves. If it does
not, halt with verdict `hold` and report the exact unresolved symbol.
The variant gets dropped from this phase; no further work.

## Assignment

Implement and evaluate `snapshot-remote-unwind`. Acceptance is by
command: `just phase2-test snapshot-remote-unwind` reports all 14
cases from `NativeStackActionTest` pass on the real collector (none
should GTEST_SKIP). `report.collector` is `"snapshot-remote-unwind"`
for every dump. Zero failures, zero crashes, zero hangs.

Read the libunwind upstream docs and headers for the remote API:

- `unw_create_addr_space`, `unw_init_remote`, `unw_destroy_addr_space`
- `unw_accessors_t` (the access-functions struct: `find_proc_info`,
  `put_unwind_info`, `get_dyn_info_list_addr`, `access_mem`,
  `access_reg`, `access_fpreg`, `resume`, `get_proc_name`)
- The `_UPT_*` "ptrace utility" helpers may be too tightly bound to
  ptrace; you may have to implement memory access against the
  copied stack snapshot directly.

ClickHouse and OceanBase do not ship this variant. Reference patterns
come from the libunwind upstream test suite and any pre-existing
in-process remote-unwind users (gdb, the JVM's safepoint, perf script).

## Pre-Verify Gate

Before writing any patches:

1. In `.worktree/phase2`, write a small probe TU at a temporary path
   (do NOT commit it) that includes `<libunwind.h>` and references
   `unw_create_addr_space` and `unw_init_remote`. Link it against
   the libunwind archive Doris already pulls in (`DORIS_DEPENDENCIES`
   in `be/CMakeLists.txt`).
2. Run a one-off compile+link inside the container via the
   `just phase2-shell` recipe (interactive) or by invoking the
   build-env image with a one-shot script. The probe must link with
   zero unresolved symbols.
3. If the link fails with `undefined reference to '_Ux86_64_create_addr_space'`
   (or any remote-mode `_Ux86_64_*` symbol), the linked archive is
   stub-only. Halt: write `evidence/phase2/variants/snapshot-remote-unwind/verdict.md`
   with status `hold`, the exact unresolved symbol, and the exact
   probe TU you used. Do NOT proceed to handler work. Do NOT
   modify `_common.sh:VARIANTS`. Do NOT export patches.
4. If the link succeeds, record the probe TU and the link command in
   `evidence/phase2/variants/snapshot-remote-unwind/build-facts.md`
   under a "Pre-verify" section, then continue.

The pre-verify is the largest budget risk for this variant. Spend ~30
minutes here at most; if the answer is not clear, halt and ask.

## Project Worktree

- Worktree: `/home/mira/lab/projects/Doris-BE-Print-Stack-API-Research/.worktree/phase2`.
- Branch: `phase2/snapshot-remote-unwind` (create from `phase2/common`).
- Patches output: `/home/mira/lab/projects/Doris-BE-Print-Stack-API-Research/patches/snapshot-remote-unwind/`.
- Evidence output: `/home/mira/lab/projects/Doris-BE-Print-Stack-API-Research/evidence/phase2/variants/snapshot-remote-unwind/`.

## Fixed Inputs

- Base commit: `c24d454f15cee2d937ef4749270a3ecb449eafe6`.
- Build image: `docker.io/apache/doris:build-env-ldb-toolchain-latest`.
- Common API patch set is frozen. Do not modify `patches/common/*`.
- Tier 2 is a later phase. Tier 1 is the only gate this round.
- Async-signal safety is deferred per charter; document; do not gate.
- Build through `just phase2-*` recipes only.

## Variant Mechanics: Handler Minimal, Coordinator Unwinds

The handler does the LEAST of all four variants:

1. Validate the realtime-signal payload (`SI_QUEUE` sender check,
   per-request `seq` token vs `slot.expected_seq`, CAS PENDING→WALKING)
   exactly like fp-walk and the libunwind variants.
2. Copy registers from `ucontext_t->uc_mcontext` into the slot
   (RIP, RBP, RSP, R-registers — whatever libunwind remote needs).
3. Copy a bounded slice of stack bytes from `[RSP, RSP + max_stack_bytes)`
   into the slot's stack buffer. Apply the same `mincore`-based
   `page_is_mapped` guard fp-walk uses for the first page; subsequent
   pages can be assumed contiguous within the stack (stack growth is
   well-defined on x86_64).
4. Restore errno, store SLOT_DONE, return.

The handler does NOT call libunwind. It does NOT call any
`dl_iterate_phdr`-touching API. The PHDR cache override (patches 1+2)
is still shipped for Tier 2 readiness — the coordinator will hit
`dl_iterate_phdr` via libunwind remote — but it never matters for
handler async-safety here.

The coordinator runs libunwind in remote mode against the snapshot:

1. Create an address space: `unw_create_addr_space(&accessors, 0)`.
2. Init from the snapshot: `unw_init_remote(&cursor, addr_space, &snapshot)`.
3. Walk: `unw_step` in a loop, bounded by `max_frames`. Use
   `unw_get_reg(&cursor, UNW_REG_IP, &pc)` per frame.
4. Destroy: `unw_destroy_addr_space(addr_space)`.

The `unw_accessors_t` is the interesting part. `access_mem` must
return stack bytes from the slot's snapshot for addresses inside
the captured window, and signal failure (return a negative
errno-equivalent) for addresses outside. `access_reg` returns
registers from the captured ucontext snapshot. `find_proc_info` and
`put_unwind_info` are typically delegated to `_UPT_find_proc_info` /
`_UPT_put_unwind_info` if the libunwind archive ships them, OR
implemented against `/proc/self/maps` plus eh_frame parsing — see
`evidence/phase2/research-summary.md` for the prior intern's notes.

## Allowed Writes

- `patches/snapshot-remote-unwind/*`.
- `evidence/phase2/variants/snapshot-remote-unwind/*`.
- Inside the worktree, source needed by your patches.

## Forbidden Writes

- `patches/common/*`.
- `patches/fp-walk/*`, `patches/ck-phdr-unwind/*`, `patches/ob-kill60/*`.
- `docs/phase2-charter.md`, `docs/phase2-acceptance.md`.

## Inherit from ck-phdr-unwind / ob-kill60

The PHDR-cache and build-system patches are intentionally duplicated
across all three libunwind variants this round (the consolidation
refactor is its own task after all three pass). Adapt these two from
`patches/ck-phdr-unwind/`:

- `patches/ck-phdr-unwind/0001-be-ck-phdr-unwind-enable-lock-free-dl_iterate_phdr-o.patch`
  → `patches/snapshot-remote-unwind/0001-be-snapshot-remote-unwind-…`.
- `patches/ck-phdr-unwind/0002-be-ck-phdr-unwind-populate-PHDR-cache-at-BE-startup.patch`
  → `patches/snapshot-remote-unwind/0002-be-snapshot-remote-unwind-…`.

For `0004-build-system`, adapt either the ck-phdr-unwind or ob-kill60
version (they ship identical content modulo the variant prefix; pick
whichever's CMake gate name reads cleaner with `snapshot-remote-unwind`).

## Expected Patch Series

1. `phdr-cache`: duplicate (re-enable Doris's commented-out override).
2. `phdr-cache-init`: duplicate (uncomment `updatePHDRCache()` at
   startup).
3. `snapshot-remote-unwind-collector`: handler captures `ucontext_t`
   regs + bounded stack bytes into the per-sequence slot. Coordinator
   reads the slot after the handler exits and runs libunwind remote
   to walk the snapshot. `report.collector = "snapshot-remote-unwind"`.
   This is the variant-specific work; expect it to be the largest patch.
4. `build-system`: Tier 2 jemalloc rebuild hook, same shape as the
   other libunwind variants.

Per-variant test file is **optional**. The snapshot+remote-unwind
model has no analog to fp-walk's case 14 / 17 (no RBP-walk in
handler) or case 15's WALKING-state pause (handler exits quickly;
WALKING is brief). The per-sequence slot ring's late-handler hazards
are tested via inherited case 12. If you want to add a
snapshot-specific case — e.g., a test that the bounded
`max_stack_bytes` slice is sufficient for a 30-frame chain — ship as
`be/test/service/http/native_stack_action_test_snapshot_remote_unwind.cpp`
with fixture `SnapshotRemoteUnwindNativeStackActionTest`. Otherwise
omit.

## Common API State at HEAD

Same as the ob-kill60 brief: per-sequence slot ring, deadline guard,
test hooks (`set_unresponsive_tid_for_test`,
`consume_deadline_budget_for_test`,
`pause_handler_for_tid_for_test`). The pause hook is fp-walk-only;
you can ignore it.

The slot's frame array (`uintptr_t frames[kMaxSignalFrames]`) is
sized for PCs, not for stack bytes. Add a separate
`uint8_t stack_bytes[kMaxStackBytes]` field to your variant's
`CaptureSlot` struct (and a matching `regs` field for the captured
registers). The common slot struct definition lives inside each
variant's `native_stack_collect.cpp` — it is not the common-api
contract; modifying it within your TU is fine.

## Known Environment Facts

- Thirdparty: `DORIS_THIRDPARTY=/var/local/thirdparty`. Do not rebuild.
- libunwind in the linked archive: pre-verify gate above. If remote
  symbols are missing, halt.
- `build.sh --be` may fail in packaging; use `just phase2-test ...`.

## Required Output

Tracked under `evidence/phase2/variants/snapshot-remote-unwind/`:

- `manifest.yaml`: commit SHAs, patch list, image ID, build/runtime
  commands, variant-specific assumptions (stack-bytes budget,
  accessors implementation, jemalloc rebuild on/off).
- `commands.sh`: exact commands to reproduce.
- `verdict.md`: `baseline-pass`, `hold`, or `fail`. On `hold` for the
  pre-verify gate, name the unresolved libunwind symbol.
- `sample-one-tid.json`: one one-TID sample.
- `build-facts.md`: pre-verify outcome (probe TU + link result),
  libunwind remote symbols confirmed (or absent), PHDR cache hit at
  coordinator time, jemalloc rebuild yes/no.

Raw / ignored: full all-thread JSON, build logs, BE logs, `/proc/<pid>/maps`,
binaries, dumps. Write under `evidence/phase2/raw/<run-id>/snapshot-remote-unwind/`
(gitignored).

## Acceptance Bar

`just phase2-test snapshot-remote-unwind` reports:

- 14 cases from `NativeStackActionTest` pass on the real collector.
- 0 or more variant-specific cases pass (optional).
- Zero failures, zero crashes, zero hangs.

`report.collector` is `"snapshot-remote-unwind"` for every dump.

Re-enroll the variant in
`scripts/phase2/_common.sh:VARIANTS="fp-walk ck-phdr-unwind ob-kill60 snapshot-remote-unwind"`.

## Stop Conditions

Stop and report (verdict.md status `hold`) when:

- **Pre-verify gate fails:** libunwind remote symbols do not resolve.
  Variant gets dropped from this phase.
- `patches/common/*` would need a change.
- The common API contract would need to shift.
- The bounded stack-bytes slice is consistently too small to satisfy
  case 8 (`KnownChainResolved`, 4-deep chain) or case 9 (`Truncated`,
  needs the `max_frames`-deep chain to actually unwind). Report the
  observed minimum bytes needed.
- The `unw_accessors_t` implementation requires reading from
  `/proc/self/maps` at coordinator time (an obvious follow-on for
  in-process remote-unwind). This is allowed; record it in
  `manifest.yaml` as a variant-specific assumption rather than
  stopping.
- libunwind crashes the coordinator. Capture the backtrace, report.
- `just phase2-test snapshot-remote-unwind` reports a flake.

## Out of Scope This Round

- Tier 2 (jemalloc profiling on/off under churn).
- Handler async-signal-safety review.
- Online symbolization.
- ADMIN/access-control.
- The PHDR-cache + build-system refactor into common — separate task
  after all 3 libunwind variants land.
