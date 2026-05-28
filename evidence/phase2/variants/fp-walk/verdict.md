status: pilot-pass

fp-walk builds, starts a standalone BE, returns raw PCs with DSO offsets, avoids
online symbols, supports one-TID and all-thread dumps, handles `busy`,
`missing_tid`, `timeout`, and `bad_request`, and survives a 50-iteration dump
loop. Offline symbolization of raw offsets resolves the API path, including
`doris::NativeStackAction::handle`.

Key results:

- all-thread sample: `status=ok`, `threads=1871`, `ok=1867`, `signal_blocked=4`, `timeout=0`, `with_multi_frame=1830`, `elapsed_ms=30`.
- one-TID sample: `tid=2523`, `frames=7`, `handler_time_ns=481`.
- repeat loop: 50 iterations, 0 failures, API latency p50/p95/p99/max `36/43/46/46 ms`.
- max per-iteration handler time observed: `17703 ns`.
- jemalloc active profiling short loop: 10 iterations, 0 failures.

Risks and gaps:

- The frame-pointer walk uses bounded RBP chasing in the signal handler. It does
  not allocate, lock, log, or symbolize in the handler, but it still dereferences
  interrupted thread stack memory.
- Four BE threads blocked the collector signal and are reported as
  `signal_blocked` rather than counted as timeout.
- Standalone BE did not prove non-ADMIN rejection because the local smoke run has
  no FE auth context; `permission-denied.status` records HTTP 200.
- Query workload, allocation pressure, dedicated thread churn, and controlled
  `dlopen`/`dlclose` churn were not run in this pilot.
