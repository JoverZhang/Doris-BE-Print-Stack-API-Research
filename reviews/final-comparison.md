# Final Comparison

status: complete

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
| `ck-phdr-unwind` | reject | libunwind in signal handler is not proven async-signal-safe |
| `ob-kill60` | reject | libunwind in signal handler plus weaker timeout behavior |
| `snapshot-remote-unwind` | reject for current build | remote libunwind is stubbed; fallback only returns depth 1 |

Recommendation:

Carry `fp-walk` forward to the next implementation/hardening step. Do not treat
this as a final production approval because the full matrix still lacks FE auth,
query workload, allocation pressure, controlled churn, and broader jemalloc
coverage.
