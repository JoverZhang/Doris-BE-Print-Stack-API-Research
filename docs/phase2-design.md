# Doris BE Stack Collection Design

> Owner: agent. Regenerated as the patches change.
> Follow [writing-guidelines.md](writing-guidelines.md) when you edit this file.
> This file explains how the API and the variants work. The goal and the gates
> live in [phase2-charter.md](phase2-charter.md) and
> [phase2-acceptance.md](phase2-acceptance.md).

## Design Space

Every variant interrupts worker threads with a realtime signal and captures
native frames. They differ in where unwinding happens and how much risk the
signal handler takes.

| Variant | Handler work | Unwind location | Main risk |
| --- | --- | --- | --- |
| `fp-walk` | walk RBP chain | handler | dereferences the interrupted RBP chain |
| `ck-phdr-unwind` | run libunwind | handler | libunwind in an async-signal context |
| `ob-kill60` | collect PCs | handler + coordinator | handler libunwind; pause while the coordinator resolves offsets |
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

Statuses: `ok`, `busy`, `timeout`, `missing_tid`, `bad_request`, plus
variant-specific states such as `signal_blocked`.

Mechanics:

- `ScopedDumpSlot` tracks one in-flight dump, so a second request returns `busy`.
- Thread ids come from `/proc/self/task`. The collector works in-process, so a
  test binary can dump its own threads.
- Collection is a free function, separate from the HTTP handler, so tests call
  it directly without forging an `HttpRequest`.

The common patch ships a stub collector that returns the JSON shape with no PCs.
Its timeout is faked by a test-only sleep hook. Real collection lives in each
variant patch.

## Variant Mechanics

### fp-walk

- Signal: `SIGRTMIN + 6`.
- The handler reads RIP and RBP from `ucontext_t`, then walks the frame chain
  into preallocated per-thread storage. Bounded by `max_frames`.
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

- OceanBase-style two-phase flow: the request thread signals targets, then a
  coordinator collects the results.
- Patch citations: `<ob>/deps/oblib/src/lib/signal/ob_signal_*.cpp`.
- Open risk: the coordinator may pause workers while it resolves DSO offsets.

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
- `ob-kill60`: does the coordinator pause workers during offset resolution?
- `snapshot-remote-unwind`: what copied stack size gives useful depth, and is a
  real remote unwinder available?
- All: what timeout is safe for a large, loaded BE process?

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
