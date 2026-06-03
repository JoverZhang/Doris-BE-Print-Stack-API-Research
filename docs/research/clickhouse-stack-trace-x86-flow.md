# ClickHouse Stack Trace X86 Flow

> Owner: agent.
> Source tree: `repos/source/ClickHouse-v26.3.10.62-lts`.
> This note explains the Linux/x86 path of ClickHouse `system.stack_trace`.

## Conclusion

ClickHouse uses a sequential coordinator and a signal handler.

The model:

- the coordinator handles one target thread at a time
- the signal payload carries the current `sequence_num`
- the signal handler writes stack data into global storage
- a kernel `pipe2()` fd carries only a sequence notification
- the coordinator waits only for `pipe_read_timeout_ms`
- a timeout discards that target's result
- late notifications are drained by sequence mismatch

The pipe is a kernel fd pipe.
It is not ClickHouse QueryPipeline `Pipe`.

## Global Synchronization State

```cpp
// Reason: identify signals sent by this process. A manual signal from another
// process must not publish data into the shared stack buffer.
// Reference: src/Storages/System/StorageSystemStackTrace.cpp:74-84.
std::atomic<pid_t> server_pid;

// Reason: each target-thread attempt gets one sequence. The signal payload and
// pipe notification both carry this value, so late responses can be ignored.
// Reference: src/Storages/System/StorageSystemStackTrace.cpp:83,492-500.
std::atomic<int> sequence_num = 0;

// Reason: the handler stores the sequence after publishing stack data. The
// coordinator checks it after the pipe wait before reading the shared buffer.
// Reference: src/Storages/System/StorageSystemStackTrace.cpp:84,172-175,517-518.
std::atomic<int> data_ready_num = 0;

// Reason: only one signal handler may write the global stack buffer at a time.
// ClickHouse says this is mainly for TSan. It also documents the single-writer
// invariant for the shared buffer.
// Reference: src/Storages/System/StorageSystemStackTrace.cpp:85,143-145,182.
std::atomic<bool> signal_latch = false;

// Reason: stack data is shared through globals. The pipe wakes the coordinator;
// it does not carry frames.
// Reference: src/Storages/System/StorageSystemStackTrace.cpp:93-111.
StackTrace stack_trace{NoCapture{}};
LazyPipeFDs notification_pipe;
```

## `signalHandler()` Flow

```cpp
// Reason: publish one interrupted thread's stack to the global buffer, then
// notify the coordinator through the pipe. The handler must stay small because
// it runs on the interrupted worker thread.
// Reference: src/Storages/System/StorageSystemStackTrace.cpp:120-183.
void signalHandler(int, siginfo_t* info, void* context) {
    // 1. Deny allocations and save errno.
    // Intent: the handler must not disturb the interrupted thread's allocator
    // state or visible errno.
    DENY_ALLOCATIONS_IN_SCOPE;
    auto saved_errno = errno;

    // 2. Validate the signal source.
    // Intent: only the coordinator in this process may use the protocol.
    if (info->si_pid != server_pid)
        return;

    // 3. Read the sequence from the signal payload.
    // Intent: the payload is the token for this capture attempt.
    int notification_num = info->si_value.sival_int;

    // 4. Drop late signals.
    // Intent: after coordinator timeout, sequence_num changes. An old handler
    // must not write data for the current attempt.
    if (notification_num != sequence_num.load(std::memory_order_acquire))
        return;

    // 5. Acquire the handler latch.
    // Intent: the global stack buffer has one writer at a time.
    bool expected = false;
    if (!signal_latch.compare_exchange_strong(
                expected, true, std::memory_order_acquire)) {
        return;
    }

    // 6. Capture from ucontext.
    // Intent: data is written to the global buffer. ClickHouse constructs
    // StackTrace here. A Doris fp-walk variant would read RIP/RBP here and
    // write fixed-size frame slots.
    const ucontext_t signal_context = *reinterpret_cast<ucontext_t*>(context);
    stack_trace = StackTrace(signal_context);

    // 7. Publish the ready sequence.
    // Intent: after the coordinator wakes from pipe poll, it still checks that
    // the data belongs to the current sequence.
    data_ready_num.store(notification_num, std::memory_order_release);

    // 8. Write the pipe notification.
    // Intent: the pipe carries only the sequence. It wakes the coordinator.
    // Frames do not travel through the pipe.
    ssize_t res = ::write(
            notification_pipe.fds_rw[1], &notification_num, sizeof(notification_num));
    (void)res;

    // 9. Restore errno and release the latch.
    // Intent: reduce visible side effects on the interrupted thread.
    errno = saved_errno;
    signal_latch.store(false, std::memory_order_release);
}
```

## `wait()` Helper Flow

```cpp
// Reason: wait for the current sequence notification. A timeout means the
// coordinator ignores this target's handler result and moves on.
// Reference: src/Storages/System/StorageSystemStackTrace.cpp:185-228.
bool wait(int timeout_ms) {
    while (true) {
        // 1. Poll the pipe read end.
        // Intent: use a bounded wait. Return false when no response arrives.
        int fd = notification_pipe.fds_rw[0];
        pollfd poll_fd{fd, POLLIN, 0};
        int poll_res = poll(&poll_fd, 1, timeout_ms);

        // 2. On EINTR, reduce the remaining wait.
        // Intent: avoid waiting forever if signals repeatedly interrupt poll.
        if (poll_res < 0) {
            if (errno == EINTR) {
                --timeout_ms;
                if (timeout_ms == 0)
                    return false;
                continue;
            }
            throw ErrnoException(...);
        }

        // 3. Timeout returns false.
        // Intent: the coordinator abandons this target and does not read the
        // global buffer.
        if (poll_res == 0)
            return false;

        // 4. Read the sequence from the pipe.
        // Intent: the pipe carries only the notification number.
        int notification_num = 0;
        ssize_t read_res = ::read(fd, &notification_num, sizeof(notification_num));

        // 5. Retry when read is interrupted by EINTR.
        if (read_res < 0) {
            if (errno == EINTR)
                continue;
            throw ErrnoException(...);
        }

        // 6. Accept only the current sequence.
        // Intent: old late-handler notifications are drained and cannot
        // contaminate the current result.
        if (read_res == sizeof(notification_num)) {
            if (notification_num == sequence_num.load(std::memory_order_relaxed))
                return true;
            continue;
        }

        // 7. Partial reads are logic errors.
        throw Exception(...);
    }
}
```

## `StackTraceSource::generate()` Flow

```cpp
// Reason: enumerate target threads, signal them one by one, wait on the
// notification pipe, and materialize rows for system.stack_trace.
// Reference: src/Storages/System/StorageSystemStackTrace.cpp:426-599.
Chunk generate() override {
    // 1. Initialize the symbol index and result columns.
    // Intent: Linux stores object-relative addresses for offline symbolization.
    const SymbolIndex& symbol_index = SymbolIndex::instance();
    MutableColumns res_columns = header->cloneEmptyColumns();

    // 2. Enumerate and filter thread IDs.
    // Intent: table predicates can reduce the target set before signaling.
    ColumnPtr thread_ids = getFilteredThreadIds();
    if (thread_ids->empty())
        return Chunk();

    const auto& thread_ids_data =
            assert_cast<const ColumnUInt64&>(*thread_ids).getData();

    // 3. Read thread names on the coordinator side.
    // Intent: this read is racy, but it does not run in the handler.
    ThreadIdToName thread_names;
    if (read_thread_names)
        thread_names = getFilteredThreadNames(predicate, context, thread_ids_data, log);

    // 4. Process each tid sequentially.
    // Intent: ClickHouse signals one thread at a time to avoid queued-signal
    // limits and result ownership ambiguity.
    for (UInt64 tid : thread_ids_data) {
        size_t res_index = 0;
        String thread_name;

        // 5. Apply thread-name filtering.
        // Intent: if the tid is filtered out by a name predicate, do not signal it.
        if (read_thread_names) {
            if (auto it = thread_names.find(tid); it != thread_names.end())
                thread_name = it->second;
            else
                continue;
        }

        // 6. Avoid signaling if the query does not need trace data.
        // Intent: reading only thread_id/thread_name should not interrupt workers.
        if (!send_signal) {
            insert_default_stack_trace_row(...);
            continue;
        }

        // 7. Check whether the target thread blocks the service signal.
        // Intent: this check is racy. ClickHouse accepts false positives and
        // false negatives because the worst case is skip or timeout.
        bool signal_blocked = isSignalBlocked(tid, STACK_TRACE_SERVICE_SIGNAL);
        if (signal_blocked) {
            insert_default_stack_trace_row(...);
            continue;
        }

        // 8. Prepare the current sequence and increment it after this target
        // attempt.
        // Intent: after timeout, a sequence increment makes late handlers fail
        // the handler-side check or get drained by wait().
        SCOPE_EXIT({
            ++sequence_num;
        });

        // 9. Send a signal to the exact Linux tid with rt_tgsigqueueinfo.
        // Intent: Linux can put the sequence in si_value.sival_int.
        siginfo_t sig_info {};
        sig_info.si_code = SI_QUEUE;
        sig_info.si_pid = server_pid;
        sig_info.si_value.sival_int =
                sequence_num.load(std::memory_order_acquire);

        if (0 != rt_tgsigqueueinfo(
                         server_pid,
                         static_cast<pid_t>(tid),
                         STACK_TRACE_SERVICE_SIGNAL,
                         &sig_info)) {
            // 10. ESRCH means the thread may have exited.
            // Intent: thread lifetime is racy; an exited thread is skipped.
            if (ESRCH == errno)
                continue;
            throw ErrnoException(...);
        }

        // 11. Wait for the pipe notification.
        // Intent: wait only pipe_read_timeout_ms. If no response arrives,
        // do not read the handler result.
        if (wait(pipe_read_timeout_ms) &&
            sig_info.si_value.sival_int ==
                    data_ready_num.load(std::memory_order_acquire)) {
            // 12. Read the global stack buffer published by the handler.
            // Intent: materialize trace only after the current sequence is
            // fully published.
            size_t stack_trace_size = stack_trace.getSize();
            size_t stack_trace_offset = stack_trace.getOffset();
            auto frame_pointers = stack_trace.getFramePointers();

            // 13. Convert each PC.
            // Intent: Linux stores an object-relative address, which is useful
            // for offline symbolization.
            Array arr;
            arr.reserve(stack_trace_size - stack_trace_offset);
            for (size_t i = stack_trace_offset; i < stack_trace_size; ++i) {
                const void* virtual_addr = frame_pointers[i];
                const auto* object = symbol_index.findObject(virtual_addr);
                uintptr_t virtual_offset =
                        object ? uintptr_t(object->address_begin) : 0;
                uintptr_t physical_addr =
                        uintptr_t(virtual_addr) - virtual_offset;
                arr.emplace_back(physical_addr);
            }

            // 14. Write a successful row.
            // Intent: only the current sequence can write trace, query_id, and
            // untracked_memory fields.
            insert_stack_trace_row(thread_name, tid, arr, ...);
            continue;
        }

        // 15. Write a default row.
        // Intent: signal-blocked and timeout cases never read the global buffer.
        insert_default_stack_trace_row(...);
    }

    // 16. Return the result chunk.
    return Chunk(std::move(res_columns), res_columns.at(0)->size());
}
```

## Doris Alignment

Doris `print_stack` should keep the ClickHouse synchronization skeleton:

- `sequence_num`
- `data_ready_num`
- `signal_latch`
- notification pipe
- `pipe2(..., O_CLOEXEC)`
- one target tid at a time
- bounded pipe wait
- discard handler results after timeout
- drain late notifications by sequence mismatch

Doris should not copy ClickHouse-specific fields into the public API:

- `query_id`
- `untracked_memory`
- ClickHouse `StackTrace`
- ClickHouse QueryPipeline `Pipe`

Doris should keep the handler small.
The handler writes a fixed-size frame buffer.
The coordinator or action layer reads thread names, resolves DSO offsets, and
serializes JSON.
