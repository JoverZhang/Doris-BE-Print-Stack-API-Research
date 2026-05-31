# Phase 2 Decision Record

## Selected Design

`fp-walk` (frame-pointer walking in the signal handler).

## Reason for Selection

The variant's handler does no libunwind, overrides no `dl_iterate_phdr`,
and depends on `-fno-omit-frame-pointer` — which Doris Release builds
already enable. This sidesteps three risk classes the other variants
carry:

- **Handler async-signal-safety.** The libunwind-in-handler variants
  (`ck-phdr-unwind`, `ob-kill60`) and the `process_vm_readv`-in-handler
  variant (`snapshot-remote-unwind`) all carry an async-safety review
  the charter explicitly defers. `fp-walk`'s handler does only
  `mincore`-guarded RBP reads and bounded frame storage; the review is
  not blocking.
- **`dl_iterate_phdr` cache machinery.** The three libunwind variants
  require Doris's PHDR-cache override to keep `dl_iterate_phdr` lock-
  free during a dump, plus a jemalloc rebuild with
  `--enable-prof-libunwind` for Tier 2 compatibility. `fp-walk`
  exercises neither path; the allocator and the loader stay on their
  default lanes.
- **Operational surface.** `fp-walk` ships one collector source file
  plus the action wiring. The libunwind variants each ship 4 patches
  with overlapping infrastructure (the PHDR cache and jemalloc rebuild
  patches are intentionally duplicated this round). Production
  maintenance cost is lower for `fp-walk`.

The Tier 1 gate is satisfied on all four variants, but Tier 1 only
proves "the harness exists." The differentiation is in Tier 2
(deferred) and in the deferred async-safety review — both of which
favor `fp-walk` structurally.

`fp-walk`'s handler has been through three rounds of codex adversarial
review (findings #1, #2, #3, fixed in commits `6ab1e6d` / `6b0343e` /
`3d1e1d9`) plus the cross-variant slot-disarm fix (`2a00713`). The
deterministic 17/17 gate after the case-8 calibration update
(`29ec6d0`) confirms the codex-hardened code path.

## Reason Each Other Design Was Rejected

### `ck-phdr-unwind` (rejected)

Runs libunwind inside the signal handler with a ClickHouse-style
PHDR-cache override. Codex review (2026-05-31 via ob-kill60 round)
flagged two HIGH-severity items that apply equally to this variant:
libunwind is not on the POSIX async-signal-safe list (`unw_init_local2`,
`unw_get_reg`, `unw_step`), and the handler has no fault containment
around DWARF reads. The fix path for both is the deferred async-safety
review (sigsetjmp/siglongjmp trampoline, code-review against the
async-safe list, TSan/ASan). Tier 1 baseline-pass was reached but does
not retire these hazards. The PHDR cache itself adds operational
surface that `fp-walk` does not pay for.

Evidence: `evidence/phase2/variants/ck-phdr-unwind/`.

### `ob-kill60` (rejected)

OceanBase-style collection with a single-phase ack — handler captures
PCs into the slot and returns, coordinator reads after the handler
exits. The single-phase form deliberately drops OB's worker-hang
(charter and design updated in commit `350f9e9`). Carries the same
handler-libunwind hazards as `ck-phdr-unwind` (codex findings #1 + #2,
deferred async-safety). The single-phase departure is a small clean-up
of OB's upstream, but it does not differentiate the variant against
`fp-walk` on the Tier 1 dimension. Tier 1 baseline-pass was reached.

Evidence: `evidence/phase2/variants/ob-kill60/`.

### `snapshot-remote-unwind` (rejected)

Handler copies registers + bounded stack bytes; coordinator unwinds
from the snapshot via libunwind's remote API. In theory the handler
does the least of the four variants. In practice the implementation
uses `process_vm_readv` inside the handler instead of plain `memcpy` +
per-page `mincore` guard. `process_vm_readv` is a syscall that
contends on the interrupted thread's `mm->mmap_lock` — strictly MORE
async-unsafe than the in-handler libunwind variants, which at least
stay in user space. Codex review surfaced this plus three other
items (accessor logic rejects DSO memory above the captured stack
window — currently masked because the variant uses
`_Ux86_64_dwarf_find_proc_info`; `page_is_mapped` rejects mapped-but-
nonresident pages; short-reads silently truncate). The theoretical
async-safety advantage is not realized in this implementation; closing
all four items would require a re-implementation. Tier 1 baseline-pass
was reached.

Evidence: `evidence/phase2/variants/snapshot-remote-unwind/`.

## Evidence Path

| Variant | Patches | Evidence | Verdict |
| --- | --- | --- | --- |
| `fp-walk` | `patches/fp-walk/` | n/a (origin baseline) | gate: 17/17 |
| `ck-phdr-unwind` | `patches/ck-phdr-unwind/` | `evidence/phase2/variants/ck-phdr-unwind/` | `baseline-pass` |
| `ob-kill60` | `patches/ob-kill60/` | `evidence/phase2/variants/ob-kill60/` | `baseline-pass` |
| `snapshot-remote-unwind` | `patches/snapshot-remote-unwind/` | `evidence/phase2/variants/snapshot-remote-unwind/` | `baseline-pass` |

All four are reproducible from the patch series under
`patches/<variant>/` against base commit
`c24d454f15cee2d937ef4749270a3ecb449eafe6` via
`just phase2-test <variant>` in the build-env container.

## Risks That Remain

The selected `fp-walk` variant ships to the next phase with these
open items:

- **Tier 2 not run.** The jemalloc-prof + alloc/thread/dlopen churn
  matrix was deferred to a follow-on phase per the user's call. The
  next phase exercises the matrix on `fp-walk` (and revisits the
  rejected libunwind variants if Tier 2 differentiation matters).
  `fp-walk` is expected to pass Tier 2 because it uses no libunwind
  and overrides no `dl_iterate_phdr`, but this is not proven yet.
- **Handler async-signal-safety review.** `fp-walk`'s handler reads
  RBP, walks the chain, restores `errno`, and returns. The only
  paths called are `clock_gettime` (POSIX async-safe via VDSO),
  `mincore` (POSIX async-safe), `atomic_*` (lock-free), and direct
  memory reads. A formal review against the POSIX async-safe list
  should still happen as part of the next phase — `fp-walk` is the
  cleanest of the four candidates here but is not free.
- **PROT_NONE guard pages.** `fp-walk`'s `mincore` guard rejects
  unmapped pages but treats PROT_NONE pages as "mapped" (they report
  resident-but-not-accessible). A `sigsetjmp`/`siglongjmp`
  trampoline would close this residual case. Documented in
  `docs/phase2-test-plan.md` case 17 and as an open Tier 2 item.
- **Walk depth on real Release-build BE stacks.** The test harness
  exercises a synthetic 4-deep marker chain plus deeper recursive
  chains for `max_frames` truncation. Real Release-build BE stacks
  through the RBP chain are an open question (carried in
  `docs/phase2-design.md` Open Design Questions).
- **Online symbolization.** Charter explicitly excludes symbolization
  from this phase. The selected variant returns raw PCs + `dso_offset`
  only; offline tools (addr2line, llvm-symbolizer) consume the
  contract.

## Process Notes

- Calibration variant: `ck-phdr-unwind` (Round 1).
- Variant fan-out: `ob-kill60` then `snapshot-remote-unwind` (Round 2,
  serial; `.worktree/phase2` is single-occupancy).
- Codex adversarial review: `ob-kill60` (2026-05-31) and
  `snapshot-remote-unwind` (2026-06-01). `fp-walk` had three prior
  codex review rounds during its initial hardening; `ck-phdr-unwind`
  inherited the cross-variant slot-disarm finding from the `ob-kill60`
  review.
- Common-api state at decision time: per-sequence slot ring + deadline
  guard + slot-disarm fix (commit `2a00713`) + case-8 calibration fix
  (commit `29ec6d0`). All four variants share this common-api seam.
- Known deferred items across the libunwind variants are recorded in
  `docs/phase2-design.md` Known Deferred Items.
