# Print Stack Architecture

> Owner: agent.
> Follow [writing-guidelines.md](writing-guidelines.md) when you edit this file.
> This file is the variant-agnostic contract and structure for the print
> stack API. Every variant implements layers 1, 2, 3-protocol, 4, and 5
> the same way. Only the capture hook in layer 3d is variant-specific.

## Decision

Use a ClickHouse-like public response.

The public API route is:

```text
/api/print_stack
```

The public request only selects the target thread:

```text
/api/print_stack
/api/print_stack?thread_id=12345
```

Do not expose implementation policy as query fields. This includes
`timeout_ms`, `pipe_read_timeout_ms`, `max_frames`, `max_stack_bytes`,
`max_copied_stack_bytes`, and `handler_time_ns`.

The public response is:

```json
{
  "threads": [
    {
      "thread_id": 12345,
      "thread_name": "brpc_worker",
      "trace": [
        { "dso": "/path/to/libdoris_be.so", "dso_offset": "0x1234" }
      ]
    }
  ]
}
```

The response carries only stack data. Internal status, collector
metadata, timeout policy, and variant-local limits stay out of JSON.

## Layers

The API has five layers.

1. Process startup installs the signal handler and opens the
   notification pipe.
2. Action layer parses the public request and emits the public
   response.
3. Coordinator and handler exchange frames through a shared slot and a
   notification pipe.
4. Coordinator resolves each captured PC to `(dso, dso_offset)`.
5. Action layer serializes the typed result to the public JSON.

Layer 3d is the only variant-specific seam: the function
`capture_into_slot`.

## Public Types

```cpp
// print_stack.h

namespace doris {

// Reason: status carries why a row has no frames. Stays in the typed
// result; the public JSON contract drops it.
// Spec: docs/architecture.md "Layer 5".
enum class ThreadStackStatus {
    // Reason: capture succeeded; frames hold the resolved trace.
    OK,
    // Reason: handler did not publish before the bounded wait expired.
    Timeout,
    // Reason: target thread had the service signal in its blocked
    //         mask. Coordinator did not send the signal.
    SignalBlocked,
    // Reason: target thread no longer exists. Send returned ESRCH.
    ThreadExited,
    // Reason: send failed for a reason other than ESRCH, or the
    //         handler stored a failure status in the slot.
    CaptureFailed,
};

// Reason: one resolved frame. (dso, dso_offset) is the canonical
// input to addr2line and llvm-symbolizer.
struct StackFrame {
    std::string dso;
    uint64_t dso_offset = 0;
};

struct ThreadStackTrace {
    int64_t thread_id = 0;
    std::string thread_name;
    ThreadStackStatus status = ThreadStackStatus::OK;
    std::vector<StackFrame> frames;
};

struct PrintStackOptions {
    std::optional<int64_t> target_thread_id;
};

struct PrintStackResult {
    std::vector<ThreadStackTrace> threads;
};

PrintStackResult collect_print_stack(const PrintStackOptions& options);

} // namespace doris
```

## Layer 1 — Process startup

```cpp
// print_stack_globals.h

namespace doris::print_stack {

// Reason: an RT signal is queued, not coalesced, so the coordinator
// drives one target after another without losing the signal in
// flight. The BE has no other SIGRT* user, and glibc reserves
// SIGRTMIN..SIGRTMIN+2. Any slot >= SIGRTMIN+3 would work; SIGRTMIN+6
// is the chosen one.
// Spec: docs/architecture.md "Layer 1".
constexpr int kServiceSignal = SIGRTMIN + 6;

// Reason: a runaway walk would block the handler. This cap sizes the
// slot's frame array.
// Spec: docs/architecture.md "Layer 1".
constexpr size_t kMaxSignalFrames = 1024;

// Reason: bounded wait the coordinator gives the handler to publish
// on the notification pipe. Short enough that one stuck thread does
// not dominate wall clock; long enough that a non-stuck thread
// always publishes. Per-thread, applied sequentially.
// Spec: docs/architecture.md "Layer 1".
constexpr int kPipeReadTimeoutMs = 100;

// Reason: handler writes frames here; coordinator reads them after
// the wait succeeds. One slot suffices because capture is sequential.
// Reference: <ck>/src/Storages/System/StorageSystemStackTrace.cpp:103.
struct StackCaptureSlot {
    // Reason: outcome the handler stored. Coordinator may overwrite
    // on Timeout, SignalBlocked, or ThreadExited.
    ThreadStackStatus status {ThreadStackStatus::CaptureFailed};

    // Reason: number of valid entries in `pcs`. Variant writes this.
    size_t frame_count {0};

    // Reason: runtime PCs the variant captured. Resolved in the
    // coordinator.
    std::array<uintptr_t, kMaxSignalFrames> pcs {};
};

// Reason: identifies signals sent by this process. A manual signal
// from another process cannot publish into the slot.
// Reference: <ck>/src/Storages/System/StorageSystemStackTrace.cpp:75.
extern std::atomic<pid_t> g_server_pid;

// Reason: every capture attempt gets a fresh sequence. Signal
// payload and pipe both carry this value.
// Reference: <ck>/src/Storages/System/StorageSystemStackTrace.cpp:83.
extern std::atomic<int> g_sequence_num;

// Reason: handler stores the sequence after frames are visible. The
// coordinator checks it before reading the slot.
// Reference: <ck>/src/Storages/System/StorageSystemStackTrace.cpp:84.
extern std::atomic<int> g_data_ready_num;

// Reason: single-writer gate for the slot.
// Reference: <ck>/src/Storages/System/StorageSystemStackTrace.cpp:85.
extern std::atomic<bool> g_signal_latch;

extern StackCaptureSlot g_slot;

// Reason: pipe carries only the sequence number. Frames travel
// through g_slot.
// Reference: <ck>/src/Storages/System/StorageSystemStackTrace.cpp:111.
extern int g_notification_pipe_rw[2];

void print_stack_signal_handler(int sig, siginfo_t* info, void* context);

void print_stack_init();

} // namespace doris::print_stack
```

```cpp
// print_stack_init.cpp

namespace doris::print_stack {
namespace {

// Reason: open the notification pipe with close-on-exec. The pipe is
// the only wakeup channel for the coordinator.
// Reference: <ck>/src/Common/PipeFDs.cpp:30-38.
void open_notification_pipe_once() {
    // 1. Create the pipe with O_CLOEXEC so a child does not inherit it.
    if (pipe2(g_notification_pipe_rw, O_CLOEXEC) != 0) {
        // 2. Initialization failure terminates startup.
    }
}

// Reason: install the service signal handler with SA_SIGINFO so the
// payload carries the sequence. SA_RESTART avoids EINTR on unrelated
// syscalls in target threads.
// Spec: docs/architecture.md "Layer 1".
void install_signal_handler_once() {
    // 1. Build sigaction with SA_SIGINFO and SA_RESTART.
    struct sigaction sa {};
    sa.sa_flags = SA_SIGINFO | SA_RESTART;
    sa.sa_sigaction = print_stack_signal_handler;
    sigemptyset(&sa.sa_mask);

    // 2. Bind the handler to the service signal.
    if (sigaction(kServiceSignal, &sa, nullptr) != 0) {
        // 3. Initialization failure terminates startup.
    }
}

} // namespace

void print_stack_init() {
    // 1. Record this process's pid so the handler can reject foreign
    //    signals.
    g_server_pid.store(getpid());

    // 2. Open the notification pipe before installing the handler so
    //    the handler always has a valid write fd.
    open_notification_pipe_once();

    // 3. Install the signal handler last.
    install_signal_handler_once();
}

} // namespace doris::print_stack
```

`doris::init_signals()` in `be/src/service/doris_main.cpp` calls
`doris::print_stack::print_stack_init()` as its last step. `main()`
invokes `init_signals()` once before any HTTP listener is bound.

## Layer 2 — Action layer

```cpp
// print_stack_action.h

namespace doris {

class PrintStackAction final : public HttpHandler {
public:
    explicit PrintStackAction(ExecEnv* exec_env);
    void handle(HttpRequest* req) override;

private:
    ExecEnv* _exec_env = nullptr;
};

} // namespace doris
```

```cpp
// print_stack_action.cpp

namespace doris {
namespace {

Status parse_print_stack_options(HttpRequest* req, PrintStackOptions* out);
std::string serialize_print_stack_result(const PrintStackResult& result);

} // namespace

void PrintStackAction::handle(HttpRequest* req) {
    // 1. Parse only the public selector.
    PrintStackOptions options;
    if (auto s = parse_print_stack_options(req, &options); !s.ok()) {
        // 1a. Reply HTTP 400 and stop.
        return;
    }

    // 2. Run the orchestration. The variant capture is chosen at link
    //    time.
    PrintStackResult result = collect_print_stack(options);

    // 3. Drop status and internal fields; emit the public JSON
    //    contract.
    std::string body = serialize_print_stack_result(result);

    // 4. Reply HTTP 200 application/json.
}

} // namespace doris
```

## Layer 3 — Coordinator and handler protocol

### 3a Invariants

- One capture in flight at a time. The single-dump gate enforces this.
- Sequence-on-payload: `rt_tgsigqueueinfo` carries `g_sequence_num` in
  `si_value`. The handler discards any signal whose payload does not
  match.
- Single-writer slot: `g_signal_latch` CAS guards `g_slot`.
- Pipe-as-notification-only: the pipe carries only the sequence
  number. Frames travel through `g_slot`.
- Late drain: the coordinator advances `g_sequence_num` on every exit
  path. A late handler fails the payload check, or the wait drains
  its pipe write.
- Selector validation: `list_target_thread_ids` filters a `thread_id`
  selector against `/proc/self/task`. An absent tid yields an empty
  target list and a request that completes with `"threads": []`. The
  ESRCH path in `capture_one` is reserved for racy mid-dump exits
  where the thread was alive at list time and gone by signal time.
- Capture is signal-safe. The variant hook must not allocate, log,
  take locks, read `/proc`, or touch Doris TLS.
- DSO resolution is not signal-safe and runs in the coordinator only.

### 3b Coordinator

```cpp
// print_stack.cpp

namespace doris {
namespace {

// Reason: only one dump can run at a time. Two would fight over the
// signal channel and the capture slot.
// Spec: docs/architecture.md "Layer 3a invariants".
std::mutex s_dump_mutex;

// list_target_thread_ids enumerates /proc/self/task. With a selector
// it returns the selector only if /proc/self/task lists it, otherwise
// an empty vector. Without a selector it returns every tid.
std::vector<int64_t> list_target_thread_ids(const PrintStackOptions& options);
std::unordered_map<int64_t, std::string> read_thread_names(
        const std::vector<int64_t>& tids);
bool is_signal_blocked(int64_t tid, int signal_number);
int remaining_ms_until(std::chrono::steady_clock::time_point deadline);

// Reason: thin wrapper over the rt_tgsigqueueinfo syscall.
// Reference: <ck>/src/Storages/System/StorageSystemStackTrace.cpp:114-118.
int rt_tgsigqueueinfo(pid_t tgid, pid_t tid, int sig, siginfo_t* info) {
    return static_cast<int>(
            syscall(__NR_rt_tgsigqueueinfo, tgid, tid, sig, info));
}

// Reason: map one captured PC to a (dso, dso_offset) pair.
// SymbolIndex is built lazily by MultiVersion<SymbolIndex>::instance()
// on first call; its construction reads dl_iterate_phdr and is not
// signal-safe, so this resolution runs in the coordinator.
// Reference: <ck>/src/Storages/System/StorageSystemStackTrace.cpp:560-563.
StackFrame pc_to_frame(uintptr_t pc) {
    const auto* obj = doris::SymbolIndex::instance()->findObject(
            reinterpret_cast<const void*>(pc));

    // 1. No DSO match: emit an empty frame.
    if (obj == nullptr) {
        return {};
    }

    // 2. dso = path the dynamic linker mapped.
    // 3. dso_offset = PC minus DSO load base. ASLR-stable.
    return {obj->name,
            pc - reinterpret_cast<uintptr_t>(obj->address_begin)};
}

// Reason: bounded read of the notification pipe. Drains notifications
// whose sequence is not the current one.
// Reference: <ck>/src/Storages/System/StorageSystemStackTrace.cpp:186-228.
bool wait_on_pipe(int timeout_ms) {
    while (true) {
        // 1. Poll the read end up to the remaining time.
        pollfd pfd {print_stack::g_notification_pipe_rw[0], POLLIN, 0};
        int rc = poll(&pfd, 1, timeout_ms);

        // 2. EINTR: shorten the bound by 1ms and continue.
        if (rc < 0 && errno == EINTR) {
            if (--timeout_ms <= 0) {
                return false;
            }
            continue;
        }

        // 3. Poll error: caller marks Timeout.
        if (rc < 0) {
            return false;
        }

        // 4. Timeout: caller marks Timeout.
        if (rc == 0) {
            return false;
        }

        // 5. Read one sequence. Pipe carries only the sequence.
        int seq = 0;
        ssize_t n = ::read(print_stack::g_notification_pipe_rw[0],
                           &seq, sizeof(seq));

        // 6. EINTR on read: continue polling.
        if (n < 0 && errno == EINTR) {
            continue;
        }

        // 7. Read error or short read: caller marks Timeout.
        if (n != static_cast<ssize_t>(sizeof(seq))) {
            return false;
        }

        // 8. Sequence match wakes the caller; mismatch drains a late
        //    notification.
        if (seq == print_stack::g_sequence_num.load(
                           std::memory_order_relaxed)) {
            return true;
        }
    }
}

// Reason: send one signal, wait bounded, copy out on match. Sequence
// advances on every exit so a late handler cannot publish into the
// next target's slot.
// Reference: <ck>/src/Storages/System/StorageSystemStackTrace.cpp:484-518.
void capture_one(int64_t tid,
                 std::chrono::steady_clock::time_point deadline,
                 ThreadStackTrace* out) {
    // 1. Skip threads that block the service signal. Racy but cheap.
    if (is_signal_blocked(tid, print_stack::kServiceSignal)) {
        out->status = ThreadStackStatus::SignalBlocked;
        return;
    }

    // 2. Advance sequence on every exit. Drains any late handler write.
    SCOPE_EXIT({ ++print_stack::g_sequence_num; });

    // 3. Build the payload with the current sequence.
    siginfo_t si {};
    si.si_code = SI_QUEUE;
    si.si_pid = print_stack::g_server_pid;
    si.si_value.sival_int = print_stack::g_sequence_num.load(
            std::memory_order_acquire);

    // 4. Send the signal to the target tid.
    if (rt_tgsigqueueinfo(print_stack::g_server_pid,
                          static_cast<pid_t>(tid),
                          print_stack::kServiceSignal,
                          &si) != 0) {
        // 4a. ESRCH means the thread already exited.
        if (errno == ESRCH) {
            out->status = ThreadStackStatus::ThreadExited;
            return;
        }
        // 4b. Any other send error.
        out->status = ThreadStackStatus::CaptureFailed;
        return;
    }

    // 5. Wait bounded for the matching sequence on the pipe.
    if (!wait_on_pipe(remaining_ms_until(deadline)) ||
        si.si_value.sival_int !=
                print_stack::g_data_ready_num.load(
                        std::memory_order_acquire)) {
        out->status = ThreadStackStatus::Timeout;
        return;
    }

    // 6. Carry the slot's outcome and resolve each captured PC.
    out->status = print_stack::g_slot.status;
    out->frames.reserve(print_stack::g_slot.frame_count);
    for (size_t i = 0; i < print_stack::g_slot.frame_count; ++i) {
        out->frames.push_back(pc_to_frame(print_stack::g_slot.pcs[i]));
    }
}

} // namespace

// Reason: orchestration shared by every variant. The per-variant step
// is the capture hook the handler invokes.
// Reference: <ck>/src/Storages/System/StorageSystemStackTrace.cpp:424-599.
PrintStackResult collect_print_stack(const PrintStackOptions& options) {
    // 1. Take the single-dump gate.
    std::scoped_lock dump_lock(s_dump_mutex);

    // 2. Select target tids by enumerating /proc/self/task and
    //    filtering by `options`. An absent selector tid yields an
    //    empty vector; the loop below then runs zero iterations.
    std::vector<int64_t> tids = list_target_thread_ids(options);

    // 3. Read thread names in the coordinator. /proc reads are racy
    //    but cheap and never happen in the handler.
    auto names = read_thread_names(tids);

    // 4. Per-thread bounded wait is a compile-time constant.
    constexpr int pipe_read_timeout_ms = print_stack::kPipeReadTimeoutMs;

    // 5. Capture each tid sequentially.
    PrintStackResult result;
    for (int64_t tid : tids) {
        ThreadStackTrace row;
        row.thread_id = tid;
        row.thread_name = names[tid];

        auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::milliseconds(pipe_read_timeout_ms);
        capture_one(tid, deadline, &row);

        result.threads.push_back(std::move(row));
    }

    return result;
}

} // namespace doris
```

### 3c Handler

```cpp
// print_stack_signal_handler.cpp

namespace doris::print_stack {

// Reason: publish one interrupted thread's frames, then notify the
// coordinator. Body runs on the interrupted worker thread and must
// stay signal-safe.
// Reference: <ck>/src/Storages/System/StorageSystemStackTrace.cpp:120-183.
void print_stack_signal_handler(int, siginfo_t* info, void* context) {
    // 1. The handler body must stay allocation-free. CK enforces
    //    this with `DENY_ALLOCATIONS_IN_SCOPE`, backed by their
    //    allocator's overload hooks. Doris jemalloc has no such
    //    hook, so the marker is kept commented out as documentation;
    //    review enforces the rule.
    // Reference: <ck>/src/Storages/System/StorageSystemStackTrace.cpp:121.
    // DENY_ALLOCATIONS_IN_SCOPE;

    // 2. Save errno so the interrupted thread does not observe a
    //    change.
    auto saved_errno = errno;

    // 3. Reject signals not sent by this process.
    if (info->si_pid != g_server_pid) {
        return;
    }

    // 4. Read the sequence from the payload.
    int seq = info->si_value.sival_int;

    // 5. Discard late deliveries.
    if (seq != g_sequence_num.load(std::memory_order_acquire)) {
        return;
    }

    // 6. Single writer enters the slot.
    bool expected = false;
    if (!g_signal_latch.compare_exchange_strong(
                expected, true, std::memory_order_acquire)) {
        return;
    }

    // 7. Variant fills the slot from the interrupted ucontext.
    capture_into_slot(*reinterpret_cast<ucontext_t*>(context), &g_slot);

    // 8. Publish the sequence after frames are visible.
    g_data_ready_num.store(seq, std::memory_order_release);

    // 9. Wake the coordinator. Pipe carries only the sequence.
    ssize_t res = ::write(g_notification_pipe_rw[1], &seq, sizeof(seq));
    (void)res;

    // 10. Restore errno and release the latch.
    errno = saved_errno;
    g_signal_latch.store(false, std::memory_order_release);
}

} // namespace doris::print_stack
```

### 3d Variant capture hook

```cpp
// print_stack_capture.h

namespace doris::print_stack {

// Reason: every variant supplies this function. The body runs inside
// the signal handler on the interrupted thread, between latch acquire
// and data_ready publish. The function MUST:
//   - not allocate, log, take locks, read /proc, or touch Doris TLS;
//   - write at most kMaxSignalFrames PCs into out->pcs;
//   - set out->frame_count to the number of valid entries;
//   - set out->status to OK on success or CaptureFailed on failure.
// Spec: docs/architecture.md "Layer 3d".
void capture_into_slot(const ucontext_t& uc, StackCaptureSlot* out);

} // namespace doris::print_stack
```

Each variant ships a `.cpp` that defines `capture_into_slot`. The
common library does not link any variant. The build picks one
implementation.

## Layer 4 — Address computation

`pc_to_frame` is declared inside the coordinator's anonymous
namespace, above. Each captured PC maps to a `(dso, dso_offset)` pair
through `SymbolIndex::findObject`.

- `dso` is the path the dynamic linker mapped. It selects the binary
  for offline symbolization.
- `dso_offset = pc - dso_runtime_load_base`. The subtraction strips
  ASLR and yields an ELF-relative address that an offline symbolizer
  can resolve from the DSO file alone.
- A PC outside every loaded DSO produces an empty `StackFrame`. The
  serializer drops it from JSON.
- `SymbolIndex` is built lazily by
  `MultiVersion<SymbolIndex>::instance()` on the first coordinator
  call. The construction reads `dl_iterate_phdr` and is not
  signal-safe. Only the coordinator calls it.

## Layer 5 — Return

`collect_print_stack` returns `PrintStackResult`. The action layer
serializes each row to the public JSON: `thread_id`, `thread_name`,
`trace`. The serializer drops `status` and any other internal field.
The BE log records non-OK status for operators.

## Differences from ClickHouse

- The public response is HTTP/JSON. CK exposes `system.stack_trace`
  as a SELECT-able table.
- Doris stores `(dso, dso_offset)` per frame. CK stores only the
  offset (its `physical_addr`) and relies on same-process
  symbolization.
- Doris does not capture `query_id` or `untracked_memory` in the
  handler.
- Doris does not reuse CK's `StackTrace` class or `QueryPipeline`
  `Pipe`.
- Doris uses `SIGRTMIN + 6`. Any RT slot at or above `SIGRTMIN + 3`
  would work; glibc reserves `SIGRTMIN..SIGRTMIN+2`. CK uses `SIGRTMIN`.
- Doris exposes a typed `ThreadStackStatus` at the coordinator
  boundary. CK encodes "no frames" as NULLs in result columns.
- Doris installs the signal handler from `init_signals()`, which
  `main()` calls once before any HTTP listener is bound. CK installs
  it lazily in the storage constructor.

## Appendix — Production deployment notes

The baseline ships without the production-hardening items below. They
belong to a later wrap-up phase, not the fp-walk baseline.

- Auth. The baseline registers `/api/print_stack` without privilege
  guards. Production should construct `PrintStackAction` with
  `(TPrivilegeHier::GLOBAL, TPrivilegeType::ADMIN)`, matching the
  existing `NativeStackAction` pattern. The route exposes per-thread
  PCs (a small information disclosure) and lets the caller force
  every BE worker to take a signal (a small denial-of-service vector),
  both of which justify admin-only access.
- Configurable timeout. `kPipeReadTimeoutMs` is a compile-time
  constant. A production deploy may want a BE config flag so an
  operator can tune the per-thread wait without recompiling.
- Allocator guard. CK forbids allocations inside the handler with a
  macro hook in their allocator. Doris jemalloc lacks the equivalent
  hook. A real guard (probably built on `je_mallctl`) would catch
  accidental allocations in the handler at runtime; the baseline
  relies on review of the handler body.

## Appendix — Offline symbolization with llvm-symbolizer

Given one frame from the JSON response:

```json
{ "dso": "/opt/doris/lib/libdoris_be.so", "dso_offset": "0x1a2b3c" }
```

Resolve with `llvm-symbolizer`:

```text
$ llvm-symbolizer --obj=/opt/doris/lib/libdoris_be.so 0x1a2b3c
doris::SegmentIterator::next_batch
/home/build/.../olap/rowset/segment_v2/segment_iterator.cpp:1234
```

The DSO file must match the build that produced the offset (same
build-id). For PIE binaries this is the only input needed; ASLR is
already stripped out by the `dso_offset` computation. For a non-PIE
binary, `dso_offset` is 0-relative and must be added to the binary's
ELF load base before symbolization. Doris BE is built PIE, so this
caveat does not apply today.
