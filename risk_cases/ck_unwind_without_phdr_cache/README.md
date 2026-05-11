# ck_unwind_without_phdr_cache

## What This Verifies

This risk case demonstrates why ClickHouse requires a prebuilt PHDR cache before
unwinding from a signal handler.

## ClickHouse Evidence

release tag: `v26.3.10.62-lts`

```text
src/Common/StackTrace.h:26
  StackTrace calculation is signal safe only if updatePHDRCache() was called beforehand.

base/base/phdr_cache.h:6
  updatePHDRCache rewrites dl_iterate_phdr with a lock-free cache-backed version.

programs/server/Server.cpp:1346
  QueryProfiler and TraceCollector are disabled without PHDR cache because
  dl_iterate_phdr is not lock free and not async-signal-safe.
```

## Run

```bash
just risk-unwind-without-phdr-cache
```

## Inputs / Outputs

| input | output | meaning |
| --- | --- | --- |
| `run_unsafe_no_phdr_cache.sh` | `unsafe_no_phdr_cache.out` | Signal-handler unwind re-enters a simulated non-async-signal-safe `dl_iterate_phdr` path and times out. |
| `run_safe_with_phdr_cache.sh` | `safe_with_phdr_cache.out` | The same signal-handler unwind completes after a ClickHouse-style PHDR cache has been prebuilt. |

## Model

The unsafe binary deliberately wraps `dl_iterate_phdr` with a fake loader lock.
It then raises a signal while that lock is held. If the signal handler unwinds
without a PHDR cache, libunwind may re-enter `dl_iterate_phdr`, hit the same
non-reentrant path, and fail to complete before the timeout.

The safe binary prebuilds a PHDR cache and serves `dl_iterate_phdr` callbacks
from the cache in the handler path. This mirrors the specific ClickHouse design
point: do expensive/locking PHDR discovery before profiler signals are enabled,
then use a lock-free cached path from the handler.

This is a deterministic model of the ClickHouse risk. It does not patch a real
ClickHouse server because current ClickHouse already calls `updatePHDRCache()`
early and disables QueryProfiler/TraceCollector when PHDR cache is unavailable.
