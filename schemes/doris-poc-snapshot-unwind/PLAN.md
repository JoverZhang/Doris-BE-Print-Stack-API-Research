# Doris POC — Snapshot-Unwind Stack Dumper

POC for an on-demand all-thread stack dumper for `doris_be`, with two implementations
behind a single header, plus a benchmark. Built with production flags
(`-O2 -fomit-frame-pointer`). Stock libunwind, no PHDR cache (Doris uses `dlopen`
at runtime so the ClickHouse freeze-cache trick does not apply).

## 1. Goals

- One header (`include/doris_stacktrace.h`), each implementation in its own `.cpp`.
- Two implementations:
  - **Impl A — kill60**: caller-driven OceanBase `kill -60`-style. Target threads
    enter a signal handler and run libunwind locally. Carried as the comparison
    baseline; has a known dlopen-vs-loader-lock risk that we accept and document.
  - **Impl B — snapshot**: caller-driven. Target threads only copy ucontext +
    bounded stack (default 8 KiB) and return immediately. The caller (entry
    thread) runs libunwind in normal context against the copied buffer via
    custom address-space accessors. Safe under concurrent `dlopen`.
- Benchmark sweeps thread count × workload × impl × copy-size. CSV output.
- Ship as one PR (header + both impls + DSO finder + workloads + bench harness +
  README + run.sh + CMake integration).

## 2. Non-goals (explicit)

- No PHDR-cache + dlopen interpose for Impl A. Impl A keeps the documented
  loader-lock risk; Impl B is the production candidate.
- No `__cxa_demangle` in the symbolization path. `dladdr` only.
- No auto-registration for Impl B. Workers must call `snapshot_register_self()`
  once at thread init. Unregistered TIDs return `status=UNREGISTERED`.
- No staged milestones. One PR.
- No eventfd/epoll ack path. Atomic-poll suffices up to 1024 threads.
- No `SignalWorker` indirection thread. Caller fans out directly.
- No frame-pointer walking. `-fomit-frame-pointer` is part of the requirement.

## 3. Layout

```
schemes/doris-poc-snapshot-unwind/
  PLAN.md                  # this file
  README.md                # design rationale, build/run, expected output
  include/
    doris_stacktrace.h     # public API
  src/
    common.cpp             # /proc enum, signal install, dladdr, Frame format
    kill60.cpp             # dump_all_threads_kill60()    (Impl A)
    snapshot.cpp           # dump_all_threads_snapshot()  (Impl B)
    dwarf_finder.cpp       # DSO cache + .eh_frame_hdr parser + custom accessors
  bench/
    bench_main.cpp         # CSV harness
    workloads.cpp          # idle / spin / alloc / lock / dlopen
    test_dso.cpp           # tiny DSO for the dlopen workload
  build.sh
  run.sh
```

Top-level integration:

- `CMakeLists.txt` gains the new targets and an `add_subdirectory` (or inline
  `repo_executable` calls following the existing pattern).
- `justfile` gains a `doris-poc-snapshot-unwind` recipe.

## 4. Public API

`include/doris_stacktrace.h`:

```cpp
namespace doris::stacktrace {

constexpr int    kCaptureSignal  = SIGRTMIN + 4;                    // overridable at build
constexpr size_t kStackCopyBytes = DORIS_STACKTRACE_COPY_BYTES;     // -D, default 8192

struct Frame {
  uintptr_t   pc;
  std::string sym;     // dladdr dli_sname, empty on miss
  uintptr_t   offset;  // pc - dli_saddr
  std::string dso;     // basename(dli_fname)
};

enum class DumpStatus { OK, TIMED_OUT, UNREGISTERED, ERROR };

struct ThreadDump {
  pid_t                    tid;
  std::string              name;
  DumpStatus               status;
  std::vector<Frame>       frames;
  bool                     truncated;
  std::chrono::nanoseconds dispatch_ns;  // entry-thread observed: t_handler_enter - t_send
  std::chrono::nanoseconds handler_ns;   // handler self: t_exit - t_enter
};

struct DumpResult {
  std::vector<ThreadDump>  threads;
  std::chrono::nanoseconds elapsed_ns;
};

// Workers using Impl B must call this once at thread init.
void snapshot_register_self();

DumpResult dump_all_threads_kill60  (std::chrono::milliseconds per_thread_timeout = std::chrono::milliseconds(100));
DumpResult dump_all_threads_snapshot(std::chrono::milliseconds per_thread_timeout = std::chrono::milliseconds(100));

} // namespace doris::stacktrace
```

## 5. Implementation A — kill60 (`src/kill60.cpp`)

Per-target frame:

```cpp
struct KillFrame {
  pid_t              tid;
  char               name[16];
  std::atomic<int>   status{0};            // 0=pending 1=ok -1=err
  uintptr_t          pcs[64];
  int                npc;
  uint64_t           t_send_ns;            // entry-thread sets
  uint64_t           t_handler_enter_ns;   // handler sets
  uint64_t           t_handler_exit_ns;    // handler sets
};
```

Entry thread:

1. Lazy-install signal handler (`pthread_once`) with
   `SA_SIGINFO | SA_NODEFER | SA_ONSTACK | SA_RESTART`.
2. Enumerate `/proc/self/task` (skip self tid).
3. Allocate `vector<KillFrame>` (one per target tid).
4. For each frame: stamp `t_send_ns = clock_gettime(CLOCK_MONOTONIC)`,
   `rt_tgsigqueueinfo(getpid(), tid, kCaptureSignal, &si)` with
   `si.si_value.sival_ptr = &frame`.
5. Poll each `frame.status.load(acquire)` with 100 ms per-thread deadline.
6. For OK frames: `dladdr` each pc → fill `Frame{pc, sym, offset, dso}`.
7. Build and return `DumpResult`.

Signal handler:

1. `KillFrame * f = (KillFrame *)si->si_value.sival_ptr;`
2. `f->t_handler_enter_ns = clock_gettime(CLOCK_MONOTONIC);`
3. `prctl(PR_GET_NAME, f->name);`
4. `unw_init_local(&cursor, &ctx)`, walk up to 64 frames, fill `f->pcs[]`.
5. `f->t_handler_exit_ns = clock_gettime(CLOCK_MONOTONIC);`
6. `f->status.store(1, release);`

Documented risk: `libunwind`'s local unwind calls `dl_iterate_phdr`, which takes
the glibc loader lock. If concurrent `dlopen` is in progress on any thread,
deadlock or long stall is possible. The `concurrent-dlopen` benchmark workload
exposes this; we do not mitigate.

## 6. Implementation B — snapshot (`src/snapshot.cpp` + `src/dwarf_finder.cpp`)

Per-target frame:

```cpp
struct SnapshotFrame {
  pid_t              tid;
  char               name[16];
  std::atomic<int>   status{0};            // 0 pending  1 ok  -1 err  -2 unregistered
  ucontext_t         ctx;
  uintptr_t          copy_start;
  size_t             copy_len;
  uint64_t           t_send_ns;
  uint64_t           t_handler_enter_ns;
  uint64_t           t_handler_exit_ns;
  alignas(16) uint8_t buffer[kStackCopyBytes];
};
```

TLS state (set by `snapshot_register_self()`):

```cpp
thread_local uintptr_t tls_stack_high = 0;
```

`snapshot_register_self()` (called once from each worker):

```cpp
pthread_attr_t attr;
pthread_getattr_np(pthread_self(), &attr);
void * base; size_t size;
pthread_attr_getstack(&attr, &base, &size);
pthread_attr_destroy(&attr);
tls_stack_high = (uintptr_t)base + size;
```

Entry thread:

1. Rebuild DSO cache (`dwarf_finder.cpp`) via `dl_iterate_phdr`. Normal context,
   safe; blocks briefly behind any in-progress `dlopen`.
2. Lazy-install signal handler.
3. Enumerate `/proc/self/task`, allocate `vector<SnapshotFrame>`.
4. Stamp `t_send_ns`, `rt_tgsigqueueinfo` with `sival_ptr=&frame` per target.
5. Poll `status.load(acquire)` with per-thread timeout.
6. For each OK frame: run remote unwind (Section 7), `dladdr` each PC.
7. Return `DumpResult`.

Signal handler (async-signal-safe — no malloc, no fprintf, no
`pthread_getattr_np`):

```cpp
SnapshotFrame * f = (SnapshotFrame *)si->si_value.sival_ptr;
f->t_handler_enter_ns = clock_gettime_safe();             // POSIX async-signal-safe
if (tls_stack_high == 0) { f->status.store(-2, release); return; }
prctl(PR_GET_NAME, f->name);
f->ctx = *(ucontext_t *)ctx;
uintptr_t rsp = f->ctx.uc_mcontext.gregs[REG_RSP];
f->copy_start = rsp;
size_t want = (tls_stack_high > rsp) ? (tls_stack_high - rsp) : 0;
f->copy_len  = want < kStackCopyBytes ? want : kStackCopyBytes;
byte_copy(f->buffer, (const void *)rsp, f->copy_len);     // hand-rolled
f->t_handler_exit_ns = clock_gettime_safe();
f->status.store(1, release);
```

The handler does not block. Worker resumes immediately.

## 7. Remote unwind from copy (`src/dwarf_finder.cpp`)

We use libunwind's generic address-space API:

```cpp
unw_accessors_t acc = {
  .find_proc_info        = my_find_proc_info,
  .put_unwind_info       = my_put_unwind_info,     // free FDE data
  .get_dyn_info_list_addr= my_get_dyn_info_list,   // return -UNW_ENOINFO
  .access_mem            = my_access_mem,          // redirect to copy or report no-mem
  .access_reg            = my_access_reg,          // serve from cursor/regs
  .access_fpreg          = my_access_fpreg,        // stub: -UNW_EINVAL
  .resume                = my_resume,              // stub: -UNW_EINVAL (we don't resume)
  .get_proc_name         = my_get_proc_name,       // delegate to dladdr or stub
};
```

`access_mem(addr, *valp)`:

```cpp
SnapshotFrame * f = arg;
if (addr >= f->copy_start && addr + 8 <= f->copy_start + f->copy_len) {
  memcpy(valp, f->buffer + (addr - f->copy_start), 8);
  return 0;
}
// Reads outside the copy region (stack we don't own) -> truncate.
// Reads of code / .eh_frame / .eh_frame_hdr live in our process address
// space and are safe; allow them via direct read.
if (is_readable_in_self_dso(addr, 8)) {
  memcpy(valp, (const void *)addr, 8);
  return 0;
}
return -UNW_EUNSPEC;
```

`is_readable_in_self_dso` consults the DSO cache (PT_LOAD ranges). This keeps
the design honest: code/eh_frame reads go through directly; stack reads outside
the 8 KiB window terminate unwind (caller marks `truncated=true`). We
deliberately do not fall back to live stack memory — the worker is running and
may have reused it.

`find_proc_info(ip, *pi, need_info, arg)`:

1. Binary-search DSO cache for the DSO containing `ip`.
2. Locate `.eh_frame_hdr` from the DSO's `PT_GNU_EH_FRAME` phdr.
3. Use `.eh_frame_hdr` binary search table to find the FDE for `ip`.
4. Call `dwarf_extract_proc_info_from_fde` (libunwind public) to fill `unw_proc_info_t`.

Per-call flow on the entry thread:

```cpp
unw_addr_space_t as = unw_create_addr_space(&acc, __BYTE_ORDER__);
unw_cursor_t cursor;
unw_init_remote(&cursor, as, &frame);   // arg threaded back to accessors
do {
  unw_word_t ip = 0;
  unw_get_reg(&cursor, UNW_REG_IP, &ip);
  pcs.push_back(ip);
} while (unw_step(&cursor) > 0);
unw_destroy_addr_space(as);
```

Then `dladdr` each pc on the entry thread to build `Frame{pc, sym, offset, dso}`.

## 8. Common (`src/common.cpp`)

- `/proc/self/task` enumeration (skip self tid). `opendir`/`readdir`, parse name as int.
- One-shot signal handler install via `pthread_once`. Each impl registers a
  separate handler under the same `kCaptureSignal` — actually they share the
  handler; the handler dispatches on `sival_ptr`'s magic tag in the first field
  (`KillFrame::tid` and `SnapshotFrame::tid` aliased differently). Simpler:
  install when first impl is invoked; both impls use the same handler and the
  handler dispatches by a `frame_kind` tag stored as the first int of each
  frame. Concrete tagging:

  ```cpp
  enum FrameKind : int { kKill = 1, kSnapshot = 2 };
  struct FrameHeader { FrameKind kind; pid_t tid; char name[16]; std::atomic<int> status; ... };
  ```

  `KillFrame` and `SnapshotFrame` start with `FrameHeader` and extend.

- `dladdr` symbolization helper.
- `Frame` printer (for the bench and the README example output).

## 9. Benchmark (`bench/`)

`bench_main.cpp`:

- Parses CLI: `--impl=kill60|snapshot --workload=idle|spin|alloc|lock|dlopen
  --threads=N --iters=K --warmup=W --out=path.csv`.
- Spawns N worker threads in chosen workload (workers call
  `snapshot_register_self()` so both impls work).
- Warmup loop: `W` dumps to prime caches and DSO cache.
- Measurement loop: `K` dumps. For each: record `elapsed_ns` and per-target
  `dispatch_ns` + `handler_ns`.
- Computes per-iter p50/p99 of pause across targets.
- Appends one CSV row per iter:

  ```
  impl,workload,thread_count,copy_bytes,iter,e2e_ns,
  pause_p50_ns,pause_p99_ns,
  dispatch_p50_ns,dispatch_p99_ns,
  truncated_count,timed_out_count,unregistered_count
  ```

`workloads.cpp`:

- `idle`: `nanosleep` loop.
- `spin`: tight arithmetic loop with deep recursion (~30 frames).
- `alloc`: `malloc` / `free` random sizes 32 B – 4 KiB.
- `lock`: shared `std::mutex[4]`, workers contend.
- `dlopen`: workers do `spin`; 1–2 dedicated threads `dlopen` + sleep(50 µs) +
  `dlclose` `libdoris_bench_dso.so` repeatedly.

`test_dso.cpp`:

- Small DSO with a few exported functions, a ctor, a dtor.
- Built as `bench/build/libdoris_bench_dso.so`.

`run.sh`:

- Builds POC + bench targets.
- Iterates the full matrix:

  ```
  impls         = [kill60, snapshot]
  workloads     = [idle, spin, alloc, lock, dlopen]
  thread_counts = [4, 32, 128, 512, 1024]
  copy_bytes    = [4096, 8192, 16384, 32768]   # snapshot only
  iters         = 200, warmup = 20
  ```

- Concatenates into `out/bench.csv`.

## 10. Build

Top-level `CMakeLists.txt` additions (following existing `repo_executable`
pattern):

- Library target `doris_stacktrace_lib` from `src/*.cpp` with
  `-O2 -fomit-frame-pointer -fasynchronous-unwind-tables -g -rdynamic
  -DDORIS_STACKTRACE_COPY_BYTES=8192`.
- Linked with `unwind`, `unwind-x86_64`, `dl`, `Threads::Threads`.
- Four `doris_stacktrace_lib.{4k,8k,16k,32k}` variants overriding
  `DORIS_STACKTRACE_COPY_BYTES`.
- `doris_poc_bench` executable from `bench/*.cpp` linked to the 8 KiB variant
  (plus parallel `bench.4k`, `bench.8k`, `bench.16k`, `bench.32k` for the
  sweep).
- `libdoris_bench_dso.so` from `bench/test_dso.cpp`.

`justfile` recipe `doris-poc-snapshot-unwind` → `build.sh` + `run.sh`.

## 11. README contents

- Goal and trade-off table (Impl A vs Impl B: pause, dlopen safety, depth cap).
- Diagram of the snapshot flow.
- Build / run instructions.
- Expected output format (sample CSV row + sample `dladdr`-resolved trace).
- Known limitations:
  - Impl B truncates beyond 8 KiB (configurable).
  - Impl A documented dlopen risk.
  - Linux x86_64 only.
  - Workers must call `snapshot_register_self()` (Impl B only).
  - Stock libunwind required; tested on system libunwind ≥ 1.5.

## 12. Implementation order (one PR, internal sequence)

1. `include/doris_stacktrace.h` + `src/common.cpp` (Frame, dladdr, /proc enum,
   signal install, FrameHeader tagging, byte_copy, clock_gettime_safe wrapper).
2. `src/kill60.cpp` end-to-end. Smoke run: 4-worker spin workload, verify OK
   frames and `dladdr` symbols.
3. `src/dwarf_finder.cpp` — DSO cache via `dl_iterate_phdr`, `.eh_frame_hdr`
   parser, custom accessors. Standalone unit test that unwinds the current
   thread via the remote API with `copy_start=RSP, copy_len=8192` and compares
   against `unw_init_local`.
4. `src/snapshot.cpp` end-to-end. Smoke run mirroring step 2.
5. `bench/test_dso.cpp` + `bench/workloads.cpp` + `bench/bench_main.cpp`.
6. `build.sh` + `run.sh` + CMake integration + `justfile` recipe.
7. `README.md`, baseline numbers from a first sweep on the dev box.

## 13. Out of scope (carried items, listed so we don't lose them)

- LD_PRELOAD/dlopen interpose for either impl.
- ARM64 support.
- C++ symbol demangling.
- Production thread-exit cleanup (current design tolerates threads exiting
  during a dump — they hit timeout and get marked `TIMED_OUT`).
- Persisting dumps to file (caller does what it wants with `DumpResult`).
