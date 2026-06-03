# Coding Guidelines

This file defines what to write and how to comment it, for code in this
repo — the patches under `patches/`, the code they introduce, and the
harness scripts under `scripts/`. Prose style follows
[writing-guidelines.md](writing-guidelines.md).

## Scope

Write only the code the patch needs.

## Labels

A comment block has one `Reason:` and one provenance label, on separate
lines.

- `Reason:` — why the code exists. Multi-line is fine.
- `Spec:` — design doc and section, in quotes. For code that implements an
  agreed decision.
- `Reference:` — source path under `repos/source` with a line range. For
  code that follows a reference implementation.
- `Local:` — no upstream source. The code is a local choice. Useful in
  variant patches to separate inherited code from local choices.

A `Reason:` may cite a contrasting source in prose. For example: "CK blocks.
OB spins. We bound the wait." The `Reference:` line carries the source the
code follows, not every source the prose mentions.

## Source aliases

Use these aliases in `Reference:` lines:

- `<ck>`: `repos/source/ClickHouse-v26.3.10.62-lts`
- `<ob>`: `repos/source/oceanbase-v4.5.0_CE`

A `Reference:` line uses an exact path and a line range. Use `:N-M` for a
range and commas for non-contiguous lines: `:123,128-129,131-134`.

```cpp
// Reference: <ck>/src/Storages/System/StorageSystemStackTrace.cpp:381-384.
```

## When a comment is required

Match a new identifier to the closest example below. The first group earns
a comment. The second stays silent.

### Required

#### Global with a `Reason:` and a `Reference:`

Namespace-scope state backed by a reference implementation.

```cpp
// Reason: the signal handler needs somewhere to publish its captured
// frames. A global slot lives forever, so a late handler never writes
// through a dangling pointer. One slot suffices because collection is
// sequential.
// Reference: <ck>/src/Storages/System/StorageSystemStackTrace.cpp:381-384.
CaptureSlot g_slot;
```

#### Global with a `Reason:` and a `Spec:`

Namespace-scope state whose policy comes from the design doc.

```cpp
// Reason: only one dump can run at a time. Two would fight over the
// signal channel and the capture slot. A contended request blocks on
// this gate until the in-flight dump finishes; contention is not
// visible in the public response.
// Spec: docs/architecture.md "Layer 3a invariants".
std::mutex s_dump_mutex;
```

#### Local choice in a variant patch

A variant-specific value with no upstream source.

```cpp
// Reason: the coordinator must wait for the handler to publish. 200
// microseconds polls often enough to keep the next thread moving without
// wasting a core on a busy yield.
// Local: fp-walk-specific cadence. No CK or OB precedent.
std::this_thread::sleep_for(std::chrono::microseconds(200));
```

#### Non-trivial helper

A function whose body is more than a few lines or carries a subtle invariant.

```cpp
// Reason: a corrupt RBP chain would otherwise read past the stack and
// could crash the process. Every RBP read must stay aligned and inside
// the interrupted thread's stack window.
// Local: fp-walk-specific safety check.
bool rbp_can_read(uintptr_t initial_rbp, uintptr_t rbp, uintptr_t max_stack_bytes) {
    ...
}
```

#### Struct field with a non-obvious invariant

Inline `Reason:` for fields with a short invariant.

```cpp
struct CaptureSlot {
    // Reason: the token gates against late-handler writes from a finished dump.
    std::atomic<uint64_t> expected_seq {0};
    ...
};
```

#### Test fixture class

A test helper that models a specific thread shape.

```cpp
// Reason: a cheap thread fixture for tests that only need a live thread
// to dump. A condition variable parks the worker until destruction.
// Local: test-only fixture.
class ParkedThread {
    ...
};
```

#### `constexpr` constant that encodes policy

A value that fixes a policy.

```cpp
// Reason: a runaway frame walk would block the handler indefinitely.
// This cap stops the walk and sizes the global slot's frame array.
// Local: fp-walk-specific cap.
constexpr int kMaxSignalFrames = 1024;
```

#### Local that carries a subtle invariant

Inline `Reason:` for locals that look like plumbing but carry an invariant.

```cpp
// Reason: capture the starting RBP once so the bounds check measures
// against a fixed anchor as rbp walks up the chain.
const uintptr_t initial_rbp = rbp;
```

#### `TEST_F` case

Every test gets `Reason: [case N] <invariant>` above the macro and numbered
comments for body beats. The case number cross-references
`docs/phase2-test-plan.md`.

```cpp
// Reason: [case 1] catches drift in the JSON contract. Required keys are
// present. No symbol-like keys leak. Frames carry only dso and
// dso_offset.
TEST_F(PrintStackActionTest, SerializeClickHouseLikeShape) {
    // 1. Run the full pipeline.
    ...

    // 2. Required root and thread keys are present.
    ...

    // 3. No symbol-like key appears anywhere.
    expect_no_symbol_keys(doc);
}
```

#### Numbered steps inside a multi-step function

A function with several core steps marks each one with a numbered comment.
Steps follow the function's top-level `Reason:` and carry no label.

```cpp
// Reason: a single orchestration shared by every variant. The per-variant
// step is the `capture_into_slot` hook the handler invokes.
// Spec: docs/architecture.md "Layer 3 — Coordinator and handler protocol".
PrintStackResult collect_print_stack(const PrintStackOptions& options) {
    // 1. Take the single-dump gate.
    ...

    // 2. Select target tids from /proc/self/task.
    ...

    // 3. Capture each thread.
    ...

    // 4. Aggregate ok / partial / timeout.
    ...
}
```

### Not required

#### Trivial helper

A small function whose name and body explain themselves.

```cpp
int64_t elapsed_ms(std::chrono::steady_clock::time_point start) {
    return static_cast<int64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
                                        std::chrono::steady_clock::now() - start)
                                        .count());
}
```

#### `constexpr` constant that is plumbing

A mechanical value with no policy.

```cpp
constexpr char kJsonContentType[] = "application/json";
```

#### Local inside a function

A scratch variable the body explains.

```cpp
int n = 0;
if (pc != 0 && n < kMaxSignalFrames) {
    g_slot.pcs[n++] = pc;
}
```

#### Test fixture field with an obvious name

The class's `Reason:` and the field's name carry enough.

```cpp
class ParkedThread {
    ...
private:
    std::thread _thread;
    std::atomic<int64_t> _tid {0};
    std::mutex _mutex;
    std::condition_variable _cv;
    bool _release = false;
};
```

## Summary rule

A name earns a `Reason:` when `name + type + body` alone do not show why it
exists or what invariant it carries. Otherwise it stays silent.

## Review rule

A reviewer should understand each patch without reading unrelated files. In the
harness, this means one commit per logical change: `git format-patch` emits one
file per commit, so commit hygiene is patch hygiene.
