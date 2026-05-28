# Stack Bytes Comparison

| max_stack_bytes | status | elapsed_ms | threads | ok | multi-frame threads | max frames/thread | copied bytes p50 | copied bytes max | dominant error |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---|
| 8192 | timeout | 4157 | 1871 | 1863 | 0 | 1 | 0 | 8192 | frame pointer chain left copied stack snapshot (1826) |
| 65536 | timeout | 4185 | 1871 | 1863 | 0 | 1 | 0 | 16976 | frame pointer chain left copied stack snapshot (1826) |

Observation: 64KiB did not improve frame depth over 8KiB in this standalone idle BE run. The signal snapshots mostly succeeded, but coordinator-side FP fallback could not walk beyond the interrupted PC because the captured frame pointer was outside the copied snapshot or unusable. libunwind remote address-space creation is unavailable in the shipped local-only libunwind archive.
