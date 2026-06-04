# ob-kill60 Variant Design

> Owner: agent.
> Follow [writing-guidelines.md](../writing-guidelines.md) when you edit this file.
> Variant-specific design for `ob-kill60`. Common layers live in
> [architecture.md](../architecture.md). The variant patch series
> modifies the common `print_stack_*` files in addition to shipping
> the variant TU. Other variant patches do not touch those files.

## Scope

Two differences from `ck-phdr-unwind`:

1. Phase 2 release handshake. The handler waits for the coordinator
   to read the slot before returning.
2. No PHDR cache. The handler runs libunwind without the lock-free
   `dl_iterate_phdr` override.

The architecture's slot, sequence-on-payload, and late-drain already
prevent slot poisoning. Phase 2 is functionally redundant. The
variant runs it to transcribe OceanBase's `kill -60` shape so the
report can compare envelopes side by side.

## Steps

1. Open `pipe2(g_handler_release_pipe_rw, O_CLOEXEC)` in
   `print_stack_init.cpp` next to the notification pipe. The pipe
   carries only the sequence number and lives for the process
   lifetime.
2. Declare `extern int g_handler_release_pipe_rw[2];` in
   `print_stack_globals.h`.
3. Declare `variant_wait_for_release(int seq)` and
   `variant_after_slot_read(int seq)` in `print_stack_capture.h`.
4. In `print_stack_signal_handler.cpp`, call
   `variant_wait_for_release(seq)` after the notification pipe
   write, before errno restore.
5. In `print_stack.cpp`, call
   `variant_after_slot_read(si.si_value.sival_int)` after the slot
   read in `capture_one`, before the `SCOPE_EXIT` bumps the
   sequence.
6. Ship `print_stack_ob_kill60.cpp`:
   - `capture_into_slot`: `unw_init_local2(... UNW_INIT_SIGNAL_FRAME)`
     seeded from the saved `ucontext_t`, walk via `unw_step` +
     `unw_get_reg(UNW_REG_IP)` up to `kMaxSignalFrames`. TU-scoped
     `UNW_LOCAL_ONLY`.
   - `variant_wait_for_release`: bounded `poll` + `read` on the
     release pipe; drain reads whose sequence does not match.
   - `variant_after_slot_read`: one `write` of the sequence into
     the release pipe.
7. Patch `thirdparty/build-thirdparty.sh build_jemalloc_doris()`:
   add `--enable-prof-libunwind` plus libunwind detection inputs
   (`CPPFLAGS`/`LDFLAGS`/`LIBS=-llzma`), verify
   `prof-libunwind : 1` in `config.log`, abort on mismatch. Same
   shape `ck-phdr-unwind` uses; different rationale (see
   Decisions).

Steps 1-5 modify common `print_stack_*` files. The patches live in
`patches/ob-kill60/` and only apply when the variant is selected.

## Decisions

1. **No PHDR cache.** `capture_into_slot` calls `unw_init_local2` +
   `unw_step` directly. `unw_step` reaches libc `dl_iterate_phdr`,
   which takes the loader lock and is not async-signal-safe.
   OceanBase ships this exact shape in production. The variant
   inherits the risk so the report's comparison against
   `ck-phdr-unwind` stays clean.
2. **Seed from the interrupted `ucontext_t`.**
   `unw_init_local2(&cursor, &ctx, UNW_INIT_SIGNAL_FRAME)` so the
   first IP read returns the interrupted PC, not the handler's own
   frame.
3. **TU-scoped `UNW_LOCAL_ONLY`.** The Doris libunwind archive
   exports only `_ULx86_64_*`. The define remaps `<libunwind.h>`.
4. **Bounded release wait.** `poll` the release pipe with
   `kPipeReadTimeoutMs` so a coordinator that errors mid-read does
   not hang the handler.
5. **Phase 2 hooks live in the variant patch, not in
   `architecture.md`.** The architecture stays single-phase. The
   variant patch is self-contained: applying it adds the second
   pipe, the two hook declarations, and the call sites in the
   common files; not applying it leaves the common files untouched.
6. **Jemalloc rebuilt with libunwind backtracer.** glibc >= 2.34
   routes `dlsym` through `malloc`. The libgcc backtracer's
   `_Unwind_Backtrace` runs during jemalloc bootstrap and
   deadlocks against the `dlsym`-driven malloc. Source:
   `<ck>/contrib/jemalloc-cmake/CMakeLists.txt:199-212`. The flag
   matches `ck-phdr-unwind`; the rationale is different. The
   `ck-phdr-unwind` rebuild also blocks the override re-entry
   deadlock under profiling load (`jemalloc/jemalloc#2504`);
   `ob-kill60` has no override, so the dlsym-bootstrap reason is
   the only reason here.

## Files

| File | Role |
|---|---|
| `be/src/service/http/action/print_stack_globals.h` | Variant patch: add release pipe extern. |
| `be/src/service/http/action/print_stack_init.cpp` | Variant patch: open the release pipe. |
| `be/src/service/http/action/print_stack_capture.h` | Variant patch: declare the two phase-2 hooks. |
| `be/src/service/http/action/print_stack.cpp` | Variant patch: call `variant_after_slot_read` after slot read. |
| `be/src/service/http/action/print_stack_signal_handler.cpp` | Variant patch: call `variant_wait_for_release` after pipe write. |
| `be/src/service/http/action/print_stack_ob_kill60.cpp` | Variant TU. Defines `capture_into_slot`, `variant_wait_for_release`, `variant_after_slot_read`. |
| `thirdparty/build-thirdparty.sh` | `build_jemalloc_doris()`: add `--enable-prof-libunwind` (+ libunwind detection inputs); verify `prof-libunwind : 1` in `config.log`. |

The harness wrapper `scripts/phase2/build-jemalloc-prof-libunwind.sh`
ensures the jemalloc source is unpacked and invokes
`build-thirdparty.sh jemalloc_doris`. Same wrapper `ck-phdr-unwind`
uses.

`be/src/service/CMakeLists.txt` already globs `*.cpp` recursively,
so the variant TU links without a CMakeLists edit.

## Why phase 2 is redundant

The architecture protects the slot already:

- Per-sequence slot ownership. A late handler write lands in the
  slot tied to its own sequence, not the next dump's slot.
- Sequence-on-payload. The handler drops at entry when its sequence
  does not match the current dump's sequence.
- Late-drain. The coordinator advances `g_sequence_num` on every
  exit path, so a late handler write into a stale slot is harmless.

OceanBase needs phase 2 because its worker writes a shared text
buffer that the target overwrites once the handler returns
(`<ob>/deps/oblib/src/lib/signal/ob_signal_worker.cpp:325-365`).
Doris has no shared buffer; the slot ring solves the race a
different way. The variant runs phase 2 for fidelity to OceanBase,
not for safety.

## Runtime dlopen / dlclose compatibility

The variant ships no `dl_iterate_phdr` override and no
`updatePHDRCache()` call, so the failure mode is the opposite of
`ck-phdr-unwind`'s.

- `ck-phdr-unwind` adds a lock-free override fed by a cached PHDR
  list. A `dlopen` after startup makes the cache stale.
- `ob-kill60` uses libc `dl_iterate_phdr` directly. The cache
  question does not apply. Every call takes the loader lock; a
  `dlopen` racing with the handler can deadlock the BE.

The BE rarely `dlopen`s after startup. The dominant site is
`be/src/util/libjvm_loader.cpp:91` on first JNI use. A request
that targets a thread mid-`dlopen` exposes the deadlock window.
Accepted; the variant exists to compare envelopes under this risk.
