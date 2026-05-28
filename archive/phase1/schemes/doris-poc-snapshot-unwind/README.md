# Doris POC — Snapshot-Unwind Stack Dumper

POC for an on-demand all-thread stack dumper for `doris_be`. Two
implementations behind a single header, plus a benchmark sweep. Built with
production flags (`-O2 -fomit-frame-pointer -fasynchronous-unwind-tables`).

See [PLAN.md](./PLAN.md) for the full design discussion.

## Layout

```
include/doris_stacktrace.h        public API
src/common.cpp                    /proc enum, signal install, dispatcher, dladdr
src/kill60.cpp                    Impl A: in-handler libunwind local
src/snapshot.cpp                  Impl B: in-handler copy ucontext + 8 KiB stack
src/dwarf_finder.cpp              DSO cache + .eh_frame_hdr + custom accessors
bench/bench_main.cpp              CSV harness
bench/workloads.cpp               idle / spin / alloc / lock / dlopen
bench/test_dso.cpp                tiny DSO loaded by the dlopen workload
bench/smoke.cpp                   end-to-end demo print
bench/remote_unwind_test.cpp      correctness: remote_unwind vs unw_init_local2
build.sh / run.sh                 wrappers around the top-level CMake build
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
| Handler async-signal-safe | no — `dl_iterate_phdr` takes the loader lock | yes — clock_gettime + prctl + bounded byte copy + atomic store |
| Stack depth | bounded by 64 frames | bounded by 64 frames AND `kStackCopyBytes` |
| Truncation | only on depth cap | on depth cap OR when unwind needs stack outside the copy window |

The snapshot handler is async-signal-safe by construction: dispatcher +
snapshot handler take no allocator paths, no `dl_iterate_phdr`, no I/O. The
kill60 handler, by contrast, calls `unw_init_local2` which goes through
`dl_iterate_phdr` and the glibc loader lock — that is the documented hazard
this POC carries as the baseline.

### Honest caveats on "dlopen safety"

The snapshot impl removes the loader-lock hazard **inside the signal handler**.
That eliminates the classic ClickHouse / OceanBase deadlock where the target
thread is mid-`dlopen` (holding the loader lock) and the in-handler
`dl_iterate_phdr` blocks.

It does **not** make the impl free of all DSO-lifecycle hazards:

- The DSO cache is rebuilt once at the start of each `dump_all_threads_snapshot`
  call on the entry thread.
- During the same call the entry thread reads code / `.eh_frame` /
  `.eh_frame_hdr` directly from those DSOs while running remote unwind.
- If another thread `dlclose`s one of those DSOs concurrently, the entry
  thread can read stale or unmapped memory and segfault.

In practice this race is small (no time elapses on the entry thread between
the cache rebuild and the unwind) but it is real and not mitigated.
Production deployments would either pin DSOs across the dump call, or move
the unwind reads behind a fault-tolerant accessor (`process_vm_readv`,
`mremap`, or a signal-safe wrapper). Out of scope for this POC.

### Lifetime / late-signal safety

Both impls heap-allocate each per-target frame and "retire" it on the entry
thread:

- If the worker published a result (`status != 0`) the frame is freed
  immediately after.
- If the worker timed out (`status == 0` at the deadline) the frame is moved
  to a process-wide graveyard. Subsequent dumps sweep the graveyard and free
  any frame whose status has since flipped.

This avoids the late-signal use-after-free where a queued `SIGRTMIN+4`
delivers minutes after the entry thread gave up. The trade is a bounded leak:
if a worker dies between signal queue and delivery, the frame stays in the
graveyard forever. That is acceptable for a POC; a production version would
add a `pthread_atfork`-style cleanup or a periodic compactor.

## Build & run

```bash
just doris-poc-build              # cmake configure + build
just doris-poc-snapshot-unwind    # build + smoke + correctness test + full sweep into bench.csv

# or manually:
./schemes/doris-poc-snapshot-unwind/build.sh
./schemes/doris-poc-snapshot-unwind/run.sh
```

`run.sh` defaults match the baseline committed to `bench.csv`:

| Variable | Default | Meaning |
| --- | --- | --- |
| `DORIS_POC_THREADS` | `4 32 128` | space-separated worker counts |
| `DORIS_POC_ITERS` | `100` | dumps per config |
| `DORIS_POC_WARMUP` | `10` | warmup dumps per config |
| `DORIS_POC_TIMEOUT_MS` | `100` | per-thread dump deadline |
| `DORIS_POC_SKIP_ABLATION` | `0` | set to `1` to skip the snapshot×spin copy-size sweep |
| `DORIS_POC_FULL_MATRIX` | `0` | set to `1` for snapshot at every copy size in every workload |

The bundled `bench.csv` was produced with the default settings (39 configs,
100 iters each, 3901 rows).

## Example output

`build/doris_poc_smoke spin 4` prints both implementations side by side:

```
=== kill60  elapsed=0.379 ms  threads=4
  tid=3023597 name=spin-0   status=OK frames= 5 trunc=0 dispatch=11.95us handler=89.15us
    #0  0x55914c2fe0f0 ?+0x0 (doris_poc_smoke)
    ...
=== snapshot  elapsed=0.291 ms  threads=4
  tid=3023597 name=spin-0   status=OK frames= 5 trunc=0 dispatch=3.06us handler=2.10us
    ...
```

Symbol resolution uses `dladdr` only (no demangling). Internal / static
symbols appear as `?+0x0`. Both impls produce the same set of PCs in idle /
spin / lock cases (within 1 frame). For a deterministic comparison, see
`bench/remote_unwind_test.cpp`, which captures the same `ucontext` for both
impls and requires identical prefix match.

## Baseline numbers

Dev-box reproduction, `iters=100 warmup=10 timeout_ms=100`, `copy_bytes=8192`,
Linux 6.19, libunwind 1.8.2.

**Pause time** (`handler_ns`) is the time the target thread is stuck in the
signal handler — the quantity that determines worst-case disruption to user
traffic.

- **`pause_p99_ns`** includes `TIMED_OUT` threads at `>= timeout_ms`, but
  `floor(0.99 * (n-1))` over 32–128 samples still excludes a single timeout
  at the tail. Use this for "typical-but-bad" behavior.
- **`pause_max_ns`** is the true per-iter max and surfaces every timeout.
  When a row's `timed_out_count > 0`, the max in that iter is exactly
  `timeout_ms × 1e6`.

Per-cell aggregation: `p50` and `p99` are the **median across iters** of the
per-iter percentiles (stable typical-case). `max` is the **strict worst
observed across all iters** of that cell (worst-case envelope; a single
timeout shows up here even if it falls outside the p99 index).

| workload | threads | kill60 p50 / p99 / **max** (µs) | snapshot p50 / p99 / **max** (µs) |
| --- | --- | --- | --- |
| idle  |   4 |   3.9 /   4.2 /     11      | 1.2 / 1.7 /     10  |
| idle  |  32 |  61.6 /  89.4 /    154      | 1.8 / 2.3 /     25  |
| idle  | 128 | 123.0 / 284.4 /    612      | 1.8 / 3.1 /     17  |
| spin  |   4 |   2.4 /   2.9 /     17      | 1.1 / 1.1 /      3  |
| spin  |  32 |  23.4 /  32.0 /  **7,009**  | 2.3 / 2.7 /  **1,812** |
| spin  | 128 |   6.1 / **2,993** / **100,000** | 2.4 / 3.2 / **100,000** |
| alloc |  32 |  19.5 /  31.1 /  **4,710**  | 3.3 / 3.8 /    988  |
| lock  |  32 |  37.5 /  51.9 /    407      | 2.3 / 2.9 /     71  |
| lock  | 128 |  43.5 / 248.6 /  **6,626**  | 2.3 / 4.4 /  **1,481** |
| dlopen|  32 |  25.2 /  33.0 /  **1,355**  | 2.3 / 2.7 /    494  |
| dlopen| 128 |   6.1 / **1,553** / **29,777** | 2.4 / 3.6 / **100,000** |

The 100,000 µs cells are 100 ms timeouts (`timeout_ms`). Both impls hit them
at 128 threads under sustained signal storm — the OS signal-delivery queue
saturates, dispatch latency stretches into multi-second territory, and a few
targets miss the per-thread deadline. **kill60 hits timeouts more often
(21 thread samples in 100 iters of `spin`/128; 3 of `alloc`/128) and has a
much higher non-timeout tail** (multi-millisecond pause from loader and
allocator contention). **snapshot keeps pause p99 ≤ 5 µs everywhere** and
its non-timeout max stays well below kill60's.

Timeout incidence in the committed sweep (each iter dumps `thread_count`
workers, so timeout opportunities = iters × thread_count):

| impl     | workload | threads | iters with ≥1 TIMED_OUT | total TIMED_OUT thread samples |
| --- | --- | --- | --- | --- |
| kill60   | alloc    | 128     | 1 / 100 | 3   |
| kill60   | spin     | 128     | 1 / 100 | 21  |
| snapshot | dlopen   | 128     | 1 / 100 | 2   |
| snapshot | spin     | 128     | 1 / 100 | 1   |

(Earlier write-ups of this POC conflated `iters_with_timeout` and
`total_timed_out_thread_samples`; the table above is the corrected
breakdown.)

**Copy-size ablation** (snapshot, spin workload only):

| threads | 4 KiB p50 / p99 | 8 KiB p50 / p99 | 16 KiB p50 / p99 | 32 KiB p50 / p99 |
| --- | --- | --- | --- | --- |
|   4 | 1.0 / 1.0 | 1.8 / 1.8 | 1.8 / 2.0 | 1.8 / 2.0 |
|  32 | 2.2 / 2.6 | 2.2 / 2.9 | 2.4 / 2.9 | 2.3 / 2.6 |
| 128 | 2.2 / 3.1 | 2.2 / 3.4 | 2.3 / 3.0 | 2.5 / 3.3 |

The handler memcpy cost is bounded enough that copy size doesn't dominate
pause; 8 KiB is the default. If 8 KiB truncates too often (deeper stacks
than the window covers), move **up** to 16 / 32 KiB. 4 KiB is acceptable
only if 8 KiB is already truncation-free and you want a marginally smaller
handler pause — dropping the window makes truncation more likely, not less.

**End-to-end** (`elapsed_ns`) is similar between the two impls at low thread
counts and somewhat higher for snapshot at 128 threads (~45 ms vs ~34 ms for
kill60 spin): snapshot moves the libunwind work from each target onto the
entry thread, trading pause time for caller time. For an interactive
`system.stack_trace`-style dump that's the right trade — the target threads
keep serving traffic; only the diagnostic caller waits.

## Correctness test

`bench/remote_unwind_test.cpp`:

1. Spawns a worker that enters a known three-frame deep call chain.
2. Sends a private signal whose handler captures both the reference PC list
   via `unw_init_local2(UNW_INIT_SIGNAL_FRAME)` AND a `SnapshotFrame` (same
   `ucontext` + bounded stack copy as the production snapshot handler).
3. Runs `internal::remote_unwind` on the SnapshotFrame from the main thread.
4. Requires the remote unwind PC sequence to be an exact prefix of the
   reference PC sequence (the remote side terminates when libunwind needs
   stack outside the copy window).

This pins the contract between the snapshot capture and the custom-accessor
DWARF walker. Run via `build/doris_poc_remote_unwind_test`; expected output
ends with `RESULT=PASS`. `run.sh` invokes this before the bench sweep.

## Known limitations

- Workers using the snapshot impl must call `snapshot_register_self()` once
  at thread init. Unregistered TIDs return `status=UNREGISTERED`.
- Snapshot truncates at `kStackCopyBytes` of stack (compile-time variants
  4 KiB / 8 KiB / 16 KiB / 32 KiB). Very deep stacks end with
  `truncated=true`.
- `kill60` keeps the documented loader-lock deadlock risk on purpose, as a
  comparison baseline. See `risk_cases/ck_unwind_without_phdr_cache/` for the
  upstream evidence.
- Snapshot's entry-thread DSO reads are NOT protected against concurrent
  `dlclose`. See "Honest caveats on dlopen safety" above.
- Linux x86\_64 only. The custom unwind accessors call
  `_Ux86_64_dwarf_search_unwind_table` and read `gregs[REG_*]` from `ucontext_t`.
- No `__cxa_demangle`. Symbol display is dladdr-raw.
- Workers that die between signal queue and delivery leak one frame each
  into the graveyard (see "Lifetime" above).

## CSV format

```
impl,workload,thread_count,copy_bytes,iter,e2e_ns,
pause_p50_ns,pause_p99_ns,pause_max_ns,
dispatch_p50_ns,dispatch_p99_ns,dispatch_max_ns,
ok_count,truncated_count,timed_out_count,unregistered_count,error_count
```

`e2e_ns` is wall clock for one `dump_all_threads_*()` call, including
`rebuild_dso_cache()` for snapshot. `dispatch_ns` is `t_handler_enter -
t_send` per target (signal delivery latency). `pause_ns` is `t_handler_exit -
t_handler_enter` per target (handler self time). p50 / p99 / max are over
the targets in a single dump; **TIMED_OUT targets are included at
`>= timeout_ms`** so worst-case pause is not understated. `pause_max_ns`
is the strict max — use it when a single timeout in `>= 100` samples would
fall outside the p99 percentile index.
