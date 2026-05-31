# Doris BE Stack Collection Design

> Owner: agent. Regenerated as the patches change.
> Follow [writing-guidelines.md](writing-guidelines.md) when you edit this file.
> This file explains how the API and the variants work. The goal and the gates
> live in [phase2-charter.md](phase2-charter.md) and
> [phase2-acceptance.md](phase2-acceptance.md). The concrete tests live in
> [phase2-test-plan.md](phase2-test-plan.md).

## Design Space

Every variant interrupts worker threads with a realtime signal and captures
native frames. They differ in where unwinding happens and how much risk the
signal handler takes.

| Variant | Handler work | Unwind location | Main risk |
| --- | --- | --- | --- |
| `fp-walk` | walk RBP chain | handler | dereferences the interrupted RBP chain |
| `ck-phdr-unwind` | run libunwind | handler | libunwind in an async-signal context |
| `ob-kill60` | run libunwind | handler | handler libunwind (single-phase ack; no worker pause) |
| `snapshot-remote-unwind` | copy regs + stack bytes | coordinator | needs a working remote unwinder |

The safest handler does the least. `snapshot-remote-unwind` copies bytes only.
`fp-walk` walks a bounded chain. `ck-phdr-unwind` and `ob-kill60` run libunwind
in the handler, which the acceptance policy treats as a safety risk.

## jemalloc compatibility

Doris BE runs jemalloc. With heap profiling on, the allocator takes its own
backtraces and holds internal locks. A handler that unwinds while a thread holds
those locks can deadlock.

The collision point is `dl_iterate_phdr`. jemalloc's profiler and libunwind's
`unw_step` both reach it. Three variants override it for caching, which breaks
jemalloc profiling unless the build is adjusted.

`ck-phdr-unwind` shows the full mitigation:

- Build jemalloc with `--enable-prof-libunwind` so its profiler uses libunwind,
  not libgcc. Confirm `backtrace_method = 'libunwind'` in jemalloc's
  `config.log`. See `patches/ck-phdr-unwind/0004-build-system.patch`.
- Cache `dl_iterate_phdr` so the override stays reentrant. See
  `patches/ck-phdr-unwind/0001-phdr-cache.patch`, Doris fix `96a46302e8c`, and
  jemalloc#2504.

`ob-kill60` and `snapshot-remote-unwind` also override `dl_iterate_phdr` and
carry the same warning in their handler-install patches.

`fp-walk` avoids all of this. It uses no libunwind and overrides no
`dl_iterate_phdr`, so the allocator path never collides with the handler. This
is the main reason it is the baseline.

## Common API

Route: `GET /api/debug/native_stack`. Source: `patches/common/`.

Request parameters:

- `tid`: optional. Dump one thread instead of all.
- `timeout_ms`: default 100, range 1..60000.
- `max_frames`: default 64.
- `max_stack_bytes`: default 8192.

Response shape:

- Root: `collector`, `status`, `timeout_ms`, `max_frames_per_thread`,
  `target_tid` when set, `elapsed`, and `threads`.
- Per thread: `tid`, `status`, `frames`, `truncated`, and an error reason on
  failure.
- Per frame: raw `pc`, `dso`, and `dso_offset`. No symbol fields.

Statuses: `ok`, `partial`, `timeout`, `missing_tid`, `bad_request`, plus
variant-specific states such as `signal_blocked`. `partial` means some threads
returned frames and others did not; per-thread status carries the detail.

Mechanics:

- A `std::timed_mutex` allows one in-flight dump. A second request waits up to
  its `timeout_ms`; if it cannot acquire the lock in time, it returns `timeout`.
  Charter: "one active dump at a time". CK blocks, OB spins; we bound the wait.
- Thread ids come from `/proc/self/task`. The collector works in-process, so a
  test binary can dump its own threads.
- Collection is a free function in three steps: `collect()` returns raw PCs,
  `resolve_dsos()` adds `dso` and `dso_offset` from `/proc/self/maps`, and
  `serialize()` writes the JSON. `collect()` is the only per-variant step. Tests
  call all three directly, without forging an `HttpRequest`.

The common patch ships a stub `collect()` that returns the shape with no PCs.
Real collection lives in each variant patch. A test-only hook marks a target tid
unresponsive, so the timeout and partial paths are testable without real
signaling.

## Variant Mechanics

### fp-walk

- Signal: `SIGRTMIN + 6`, queued with `SI_QUEUE` so the handler can read the
  request token.
- Collection is sequential. The coordinator signals one thread, waits for it on
  a single global capture slot, then moves to the next. This bounds queued
  signals and keeps the slot model simple.
  Reference: CK signals one thread at a time for the same reason,
  `<ck>/src/Storages/System/StorageSystemStackTrace.cpp:381-384`.
- A monotonic sequence number rides in the signal payload. The handler writes to
  the slot only if the payload matches the current request, so a late handler
  from a finished dump drops its result. This closes the late-responder window.
  Reference: `<ck>/src/Storages/System/StorageSystemStackTrace.cpp:131-134,499-506`.
- The handler reads RIP and RBP from `ucontext_t`, walks the frame chain into the
  global slot, bounded by `max_frames`, then restores `errno`. It ignores any
  signal whose sender is not this process.
  Reference: errno save/restore and the `si_pid` sender check,
  `<ck>/src/Storages/System/StorageSystemStackTrace.cpp:123,128-129,180`.
- Threads that block the signal are reported as `signal_blocked`, not as
  timeouts.
- Needs `-fno-omit-frame-pointer`. The research summary finds Doris already
  builds Release with this flag, and the fp-walk patch adds no build flag.
  Confirm on the first build.
- Uses no libunwind and no `dl_iterate_phdr` override, so it avoids the
  allocator collision described under jemalloc compatibility.
- Records handler time per thread.

### ck-phdr-unwind

- Runs libunwind inside the handler, with a ClickHouse-style PHDR cache so the
  unwinder avoids `dl_iterate_phdr` at unwind time.
- Patch citations: `<ck>/base/base/phdr_cache.cpp`,
  `<ck>/src/Storages/System/StorageSystemStackTrace.cpp`.
- The shipped libunwind archive exposes local-only `_ULx86_64_*` symbols; the
  build defines `UNW_LOCAL_ONLY`.

### ob-kill60

- OceanBase-style collection with a single-phase ack. The request thread
  signals targets with a per-request `req_id` in the payload; each handler
  captures its frames into the slot and returns immediately; the coordinator
  reads the slot after the handler exits and resolves DSO offsets. The
  worker never hangs.
- OceanBase's upstream form is two-phase: the target thread hangs in its
  handler while the coordinator resolves, then is told to exit. Reference:
  `<ob>/deps/oblib/src/lib/signal/ob_signal_worker.cpp:280-347`. The
  upstream worker-hang is the part we deliberately drop; single-phase
  removes the coordinator-induced worker pause that is OB's main open risk.
- Patch citations: `<ob>/deps/oblib/src/lib/signal/ob_signal_*.cpp` for
  the signal token and slot mechanics; the variant patch supplies its own
  single-phase coordinator instead of OB's two-phase resolver.

### snapshot-remote-unwind

- The handler copies registers and bounded stack bytes only. No libunwind in the
  handler.
- The coordinator unwinds from the snapshot.
- Open risk: the linked thirdparty libunwind stubbed remote address-space
  creation in the previous run. Check remote-unwind capability before depending
  on it.

## Open Design Questions

- `fp-walk`: how deep are real Release-build BE stacks through the RBP chain?
- `ck-phdr-unwind` and `ob-kill60`: can handler-side libunwind be proven
  async-signal-safe? Deferred to the next phase per the acceptance doc.
- `snapshot-remote-unwind`: what copied stack size gives useful depth, and is a
  real remote unwinder available?
- All: what timeout is safe for a large, loaded BE process?

## Known Deferred Items

Codex adversarial review of `ob-kill60`'s handler (2026-05-31) surfaced
hazards that apply to the libunwind variants as a class. Finding #4
(slot-disarm race on the success path) was fixed across all three
variants (commit `2a00713`); these three remain open and are deferred
by design:

- **Libunwind in handler is async-signal-unsafe** (`ck-phdr-unwind`,
  `ob-kill60`). `unw_init_local2` / `unw_get_reg` / `unw_step` are not
  on the POSIX async-signal-safe list. The PHDR-cache override
  (patches `0001` + `0002`) keeps the one known `dl_iterate_phdr` path
  lock-free but does not cover the broader libunwind contract.
  Deferred to the next phase per
  [phase2-acceptance.md](phase2-acceptance.md) "Deferred to the next
  phase". The review is async-safety code review + TSan/ASan, not a
  Tier 1 green test.

- **No fault containment around libunwind reads** (`ck-phdr-unwind`,
  `ob-kill60`). A malformed unwind state could make the handler touch
  unmapped memory. `fp-walk` has the equivalent guard for raw RBP
  reads (`mincore`-based `page_is_mapped`); the libunwind variants
  would need a `sigsetjmp`/`siglongjmp` trampoline. Bundled with the
  async-safety review above.

- **Libunwind init/get/step errors collapse into `status: ok` with
  zero frames** (`ck-phdr-unwind`, `ob-kill60`). The collectors do not
  distinguish unwind failure from end-of-stack. A future status-shape
  refinement task should add an `unwind_failed` status (or equivalent
  partial-error reason) across both variants together. Not race-class;
  the gate is unaffected.

## Environment Notes

The dispatch brief records the build landmines: the `build.sh` bind-mount
packaging failure, the libunwind symbol prefixes, and the remote-unwind stub.
See [../evidence/phase2/subagent-brief-template.md](../evidence/phase2/subagent-brief-template.md).

## References

- Doris live native-stack PR: apache/doris#22549.
- ClickHouse jemalloc build flags: ClickHouse `contrib/jemalloc-cmake`.
- jemalloc `--enable-prof-libunwind` regression: jemalloc#2504.
- Doris jemalloc profile fix: commit `96a46302e8c`.
- Origin research: [../evidence/phase2/research-summary.md](../evidence/phase2/research-summary.md).
