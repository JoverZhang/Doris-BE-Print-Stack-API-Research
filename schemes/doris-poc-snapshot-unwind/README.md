# Doris POC — Snapshot-Unwind Stack Dumper

POC for an on-demand all-thread stack dumper for `doris_be`. Two
implementations behind a single header, plus a benchmark sweep. Built with
production flags (`-O2 -fomit-frame-pointer -fasynchronous-unwind-tables`).

See [PLAN.md](./PLAN.md) for the full design discussion.

## Layout

```
include/doris_stacktrace.h     public API
src/common.cpp                 /proc enum, signal install, dispatcher, dladdr
src/kill60.cpp                 Impl A: in-handler libunwind local
src/snapshot.cpp               Impl B: in-handler copy ucontext + 8 KiB stack
src/dwarf_finder.cpp           DSO cache + .eh_frame_hdr + custom accessors
bench/bench_main.cpp           CSV harness
bench/workloads.cpp            idle / spin / alloc / lock / dlopen
bench/test_dso.cpp             tiny DSO loaded by the dlopen workload
bench/smoke.cpp                end-to-end demo print
build.sh / run.sh              wrappers around the top-level CMake build
```

Top-level CMake builds the library in four `copy_bytes` variants (4 KiB,
8 KiB, 16 KiB, 32 KiB), each linked into its own bench executable; the
production target is the 8 KiB variant.

## Public API

```cpp
namespace doris::stacktrace {

inline int capture_signal();                       // SIGRTMIN + 4
constexpr std::size_t kStackCopyBytes;             // -DDORIS_STACKTRACE_COPY_BYTES, default 8192

struct Frame    { uintptr_t pc; std::string sym; uintptr_t offset; std::string dso; };
enum  class DumpStatus { OK, TIMED_OUT, UNREGISTERED, ERROR };
struct ThreadDump { pid_t tid; std::string name; DumpStatus status;
                    std::vector<Frame> frames; bool truncated;
                    std::chrono::nanoseconds dispatch_ns, handler_ns; };
struct DumpResult { std::vector<ThreadDump> threads; std::chrono::nanoseconds elapsed_ns; };

void       snapshot_register_self();               // workers (Impl B) call once at init
DumpResult dump_all_threads_kill60  (std::chrono::milliseconds per_thread_timeout = 100ms);
DumpResult dump_all_threads_snapshot(std::chrono::milliseconds per_thread_timeout = 100ms);

}
```

The two free functions are the entire API. Both can be called from any
thread; they enumerate `/proc/self/task`, fan out `SIGRTMIN+4` directly via
`rt_tgsigqueueinfo`, wait for the targets to publish results, and return one
`ThreadDump` per target.

## Impl A vs Impl B

| | **Impl A — kill60** | **Impl B — snapshot** |
| --- | --- | --- |
| Handler does | `unw_init_local2` + walk → store PCs | copy `ucontext_t` + ≤ 8 KiB stack → set status |
| Entry thread does | `dladdr` per PC | DSO-cache remote unwind via custom libunwind accessors, then `dladdr` |
| Worker registration | none | once per thread, before first dump |
| `dlopen` safety | unsafe (loader-lock deadlock under contention) | safe (handler does no allocator / dl_iterate_phdr) |
| Stack depth | bounded by 64 frames | bounded by 64 frames AND `kStackCopyBytes` |
| Truncation | only on depth cap | on depth cap OR when unwind needs stack outside the copy window |

The snapshot handler is async-signal-safe by construction: it does
`clock_gettime(CLOCK_MONOTONIC)`, `prctl(PR_GET_NAME, …)`, a hand-rolled
byte copy of `≤ 8 KiB`, and an atomic store. No `malloc`, no `dl_iterate_phdr`,
no I/O.

## Build & run

```bash
just doris-poc-build              # cmake configure + build
just doris-poc-snapshot-unwind    # build + smoke + full sweep into bench.csv

# or manually:
./schemes/doris-poc-snapshot-unwind/build.sh
./schemes/doris-poc-snapshot-unwind/run.sh
```

`run.sh` honours these env vars:

| Variable | Default | Meaning |
| --- | --- | --- |
| `DORIS_POC_THREADS` | `4 32 128` | space-separated worker counts |
| `DORIS_POC_COPY_VARIANTS` | `4k 8k 16k 32k` | which copy-size variants to exercise |
| `DORIS_POC_ITERS` | `200` | dumps per config |
| `DORIS_POC_WARMUP` | `20` | warmup dumps per config |
| `DORIS_POC_TIMEOUT_MS` | `100` | per-thread dump deadline |

## Example output

`build/doris_poc_smoke spin 4` prints both implementations side by side:

```
=== kill60  elapsed=0.379 ms  threads=4
  tid=3023597 name=spin-0   status=OK frames= 5 trunc=0 dispatch=11.95us handler=89.15us
    #0  0x55914c2fe0f0 ?+0x0 (doris_poc_smoke)
    #1  0x55914c2fe18a ?+0x0 (doris_poc_smoke)
    ...
=== snapshot  elapsed=0.291 ms  threads=4
  tid=3023597 name=spin-0   status=OK frames= 5 trunc=0 dispatch=3.06us handler=2.10us
    ...
```

Symbol resolution uses `dladdr` only (no demangling). Internal / static symbols
appear as `?+0x0`. Both impls produce the same set of PCs in the spin / idle /
lock cases (within 1 frame).

## Baseline numbers

Dev-box reproduction, `iters=100 warmup=10`, `copy_bytes=8192`, Linux 6.19,
libunwind 1.8.2. **Pause time** (`handler_ns`) is the time the target thread
is stuck inside the signal handler — the quantity that determines worst-case
disruption to user traffic.

| workload | threads | kill60 pause p50 / p99 (µs) | snapshot pause p50 / p99 (µs) | speedup p50 / p99 |
| --- | --- | --- | --- | --- |
| idle  |   4 |   6.7 /   7.4 |  1.8 / 1.8 |  3.7× /  4.1× |
| idle  |  32 |  64.6 /  90.8 |  1.9 / 2.6 | 34×  /  35×   |
| idle  | 128 | 120.2 / 286.5 |  1.9 / 3.2 | 65×  /  91×   |
| spin  |   4 |   2.6 /   3.1 |  1.1 / 1.2 |  2.4× /  2.7× |
| spin  |  32 |  21.0 /  31.4 |  2.3 / 2.7 |  9.1× / 11.6× |
| spin  | 128 |   5.4 / **2990** | 2.3 / 3.1 |  2.4× /  950× |
| alloc |  32 |  20.7 /  30.6 |  3.3 / 4.0 |  6.4× /  7.7× |
| lock  |  32 |  37.2 /  51.9 |  2.1 / 2.8 | 17×  /  19×   |
| dlopen|  32 |  23.9 /  32.5 |  2.2 / 2.7 | 11×  /  12×   |
| dlopen| 128 |   6.0 / 290.4 |  2.4 / 3.4 |  2.5× /  85×  |

The snapshot impl holds pause-p99 below **5 µs at every workload and thread
count tested**; kill60's pause-p99 explodes under contention (loader lock,
allocator lock) and especially in the `dlopen` workload that exercises the
documented `dl_iterate_phdr` hazard. In that workload kill60 also times out:
**99 of 100 iters at 128 threads** had at least one TIMED_OUT thread, vs.
1 of 100 for snapshot.

Copy-size ablation (snapshot, spin workload) confirms the choice of 8 KiB:
pause p50 stays within 2.2 – 2.4 µs across 4 / 8 / 16 / 32 KiB. The CSV
contains the per-iter breakdown.

End-to-end (`elapsed_ns`) is similar between the two impls at low thread
counts and higher for snapshot at 128 threads — that's expected: snapshot
moves the libunwind work from the targets onto the entry thread, trading
pause time for caller time. For an interactive `system.stack_trace`-style
dump that is the right trade.

## Known limitations

- Workers using the snapshot impl must call `snapshot_register_self()` once
  at thread init. Unregistered TIDs return `status=UNREGISTERED`.
- Snapshot truncates at 8 KiB of stack (configurable via the
  `DORIS_STACKTRACE_COPY_BYTES` CMake variants). For very deep stacks the
  trace ends with `truncated=true`.
- `kill60` keeps the documented loader-lock deadlock risk on purpose, as a
  comparison baseline. See `risk_cases/ck_unwind_without_phdr_cache/` for the
  upstream evidence.
- Linux x86\_64 only. The custom unwind accessors call
  `_Ux86_64_dwarf_search_unwind_table` and read `gregs[REG_*]` from `ucontext_t`.
- No `__cxa_demangle`. Symbol display is dladdr-raw.
- Workers that exit between signal send and status poll are reported as
  `TIMED_OUT` (the entry thread waits up to `per_thread_timeout`).

## CSV format

```
impl,workload,thread_count,copy_bytes,iter,e2e_ns,
pause_p50_ns,pause_p99_ns,dispatch_p50_ns,dispatch_p99_ns,
ok_count,truncated_count,timed_out_count,unregistered_count,error_count
```

`e2e_ns` is the wall clock duration of one `dump_all_threads_*()` call,
including `rebuild_dso_cache()` for snapshot. `dispatch_ns` is
`t_handler_enter - t_send` per target (signal delivery latency). `pause_ns` is
`t_handler_exit - t_handler_enter` per target (handler self time). p50/p99 are
computed across the targets of a single dump.
