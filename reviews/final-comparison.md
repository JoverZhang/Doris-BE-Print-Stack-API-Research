# Final Comparison - Attempt 1

status: superseded-by-protocol

Compared variants:

- `fp-walk`: `0c99c8f877497feb9f02201f747272c485a46cce`
- `ck-phdr-unwind`: `d7394889fc2689a3c5bd9189d5976fbe8e335a1a`
- `ob-kill60`: `dc29ca4bc404f6b9267c60dfa9a058c0905dfebd`
- `snapshot-remote-unwind`: `054789ee2cf9af3d4c483e93fe2b814f96031d41`

Patch replay:

- Common patch applies to base.
- Every variant patch applies cleanly on top of common.

Summary:

| variant | result | main reason |
|---|---|---|
| `fp-walk` | lead candidate | useful multi-frame stacks without libunwind in the handler |
| `ck-phdr-unwind` | policy fail if handler libunwind is forbidden | frame quality is good; safety proof absent |
| `ob-kill60` | hold plus policy issue | handler libunwind; timeout tail needs root-cause instrumentation |
| `snapshot-remote-unwind` | current implementation blocked | remote libunwind is stubbed; stack-depth/unwinder sweep incomplete |

Recommendation:

Carry `fp-walk` forward as the first hardening candidate, but do not ask for
production review from this package. The next round must use
`evidence/phase2/evaluation-protocol.md`; skipped required rows and unrooted
timeout tails must produce `hold`, not narrative rejection.
