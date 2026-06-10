# snapshot-remote-unwind Variant Design

> Owner: agent.
> Follow [writing-guidelines.md](../writing-guidelines.md) when you edit this file.
> Variant-specific design for `snapshot-remote-unwind`. Common layers
> live in [architecture.md](../architecture.md). The variant patch
> series modifies the common `print_stack_*` files in addition to
> shipping the variant TU. ob-kill60 also modifies the common files,
> but adds different hooks for a different reason.

## Scope

Three differences from `ck-phdr-unwind`:

1. The handler runs no unwinder. It copies the interrupted thread's
   `ucontext_t` and a bounded slice of its stack into a variant-local
   snapshot ring, then returns. Signal safety is a property of the
   handler body alone: one structure copy plus one
   `process_vm_readv` syscall.
2. The coordinator runs libunwind in remote mode against the
   snapshot, in the request thread. `unw_create_addr_space` with
   custom accessors, `unw_init_remote` seeded from the captured
   `ucontext_t`, then `unw_step` + `unw_get_reg` up to
   `kMaxSignalFrames`. The custom `access_mem` reads stack words
   from the snapshot bytes; the custom `access_reg` reads from the
   captured registers. `dl_iterate_phdr` takes the loader lock,
   which is allowed in the coordinator.
3. The coordinator pipelines. After tid_N's handler publishes, the
   coordinator queues tid_{N+1}'s signal and unwinds tid_N's
   snapshot while tid_{N+1}'s handler runs. Pipeline depth is 1.
   The snapshot ring has two buffers, keyed by sequence parity.

Not shipped:

- Lock-free `dl_iterate_phdr` override. The handler does not call
  `dl_iterate_phdr`; the coordinator does, in a request thread,
  where the loader lock is allowed.
- `updatePHDRCache()` at startup. Nothing to populate.
- `hasPHDRCache()` gate. Nothing to gate.
- Jemalloc rebuild. The handler does not call any unwinder, so the
  libgcc-backtracer-against-loader deadlock cannot reach the
  handler path.

## Reuse, adjust, add

What the variant adjusts in common files:

- Move the coordinator helpers out of the anonymous namespace in
  `print_stack.cpp` so the variant TU can call them.
  Affected: `list_target_thread_ids`, `read_thread_names`,
  `is_signal_blocked`, `rt_tgsigqueueinfo`, `remaining_ms_until`,
  `wait_on_pipe`. Pure rename; no behavior change.
- Add `variant_walk_snapshot(int seq, ThreadStackTrace* out)` to
  `print_stack_capture.h`.
- Replace `collect_print_stack`'s body in `print_stack.cpp` with the
  pipelined coordinator. The new body uses the same helpers plus
  the `variant_walk_snapshot` hook. The single-dump gate, the tid
  list, and the names lookup are unchanged.
- Add `libunwind-x86_64.a` to `be/cmake/thirdparty.cmake`, gated on
  `CMAKE_BUILD_TARGET_ARCH == x86_64`. The default `libunwind.a`
  archive ships `_ULx86_64_init_remote` as a 6-byte stub returning
  `-UNW_EINVAL`; the real remote-mode entry points live only in the
  per-arch archive under `_Ux86_64_*`. See decision #12.

What the variant adds:

- `print_stack_snapshot_remote_unwind.cpp`: the variant TU.
  - `capture_into_slot`: handler-side snapshot fill. Copy
    `ucontext_t` into the ring slot. Read RSP from the saved
    registers. `process_vm_readv(self -> self)` from
    `[RSP, RSP + cap)` into the slot's `stack_bytes`, recording
    `stack_base` and `stack_size`. Sets `slot->status = OK` and
    `slot->frame_count = 0`.
  - `variant_walk_snapshot`: coordinator-side libunwind remote
    walk. Build `unw_accessors_t`, call `unw_create_addr_space`,
    set the TLS active-slot pointer, `unw_init_remote(&cursor,
    addr_space, &snap.regs)`, loop `unw_step` + `unw_get_reg`
    up to `kMaxSignalFrames`, push each PC to `out->frames`
    via `pc_to_frame`. Clear the TLS pointer, destroy the addr
    space.
  - Custom `unw_accessors_t`:
    - `access_reg`: read from the saved `ucontext_t.uc_mcontext.gregs`,
      mapping `UNW_X86_64_R<N>` to `REG_R<N>`. Refuse writes with
      `-UNW_EREADONLYREG`.
    - `access_mem`: serve stack words from `stack_bytes` for
      addresses inside `[stack_base, stack_base + stack_size)`.
      For addresses at or above `stack_base` but outside the
      captured tail, return `-UNW_EINVAL` (fail closed). For
      addresses below `stack_base`, do a live in-process read
      with a `mincore` guard.
    - `find_proc_info` / `put_unwind_info`: delegate to the
      `_Ux86_64_dwarf_find_proc_info` /
      `_Ux86_64_dwarf_put_unwind_info` helpers exported from
      `libunwind-x86_64.a`. Declared with `extern "C"` in-TU
      because the public headers do not expose them but the
      archive does.
    - `get_dyn_info_list_addr`: return 0 (Doris does not JIT
      eh_frame entries).
    - `resume` / `get_proc_name`: unused. Return `-UNW_EINVAL` /
      `-UNW_ENOINFO`.
  - `g_snapshots[2]`: handler-to-coordinator snapshot ring. Each
    slot holds the captured `ucontext_t`, `stack_base`,
    `stack_size`, and a `uint8_t stack_bytes[kMaxSnapshotBytes]`
    buffer. Keyed by `seq % 2`.
  - `tls_active_snapshot`: thread-local pointer the coordinator
    sets before `unw_init_remote` and clears after
    `unw_destroy_addr_space`. `access_mem` reads it. libunwind
    passes one `void* arg` to every accessor (the variant uses
    it for the `ucontext_t` pointer that `access_reg` needs);
    the TLS pointer carries the snapshot pointer that
    `access_mem` needs.

## Multi-threaded interactions

Actors:

- Coordinator: the request thread that runs `collect_print_stack`.
- Handler: runs on the interrupted target thread, one at a time
  under the single-dump gate.

Shared state:

| Owner | Field | Role |
|---|---|---|
| Common | `g_sequence_num` | Coordinator reads, increments. Handler reads to check entry. |
| Common | `g_data_ready_num` | Handler writes. Coordinator reads after `wait_on_pipe`. |
| Common | `g_signal_latch` | Handler CAS. Single-writer gate. |
| Common | `g_slot` | Touched only to carry status and frame count. The variant sets `frame_count = 0` and `status = OK`. |
| Common | `g_notification_pipe_rw` | Handler writes the sequence. Coordinator polls and reads. |
| Variant | `g_snapshots[2]` | Handler writes `g_snapshots[seq % 2]` (`ucontext_t` + stack window). Coordinator reads the pending parity. |
| Variant | `tls_active_snapshot` | Coordinator sets before `unw_init_remote`, clears after `unw_destroy_addr_space`. `access_mem` reads it. |

Invariants:

1. At most one signal is in flight. The coordinator sends, waits,
   then sends the next.
2. At most one in-flight unwind. Pipeline depth is 1.
3. Two adjacent successful sends carry sequences `seq` and `seq + 1`.
   Their parities differ. The handler at `seq` writes
   `g_snapshots[seq % 2]`; the handler at `seq + 1` writes
   `g_snapshots[(seq + 1) % 2]`. The two buffers are disjoint.
4. The coordinator advances `g_sequence_num` only after a successful
   wait or a timeout-after-send. Signal-blocked and send-failed
   paths do not advance. A late handler whose sequence does not
   match `g_sequence_num` drops at entry.
5. The coordinator's read of `g_snapshots[pending_seq % 2]` cannot
   race the next handler's write. The next handler writes the
   opposite parity by invariant 3.

Coordinator state machine (one iteration per tid):

```text
input:   tid_i, deadline_i
state:   pending_idx, pending_seq   (-1 if no pending unwind)
output:  result.threads[i] populated

1. row = result.threads[i]
2. if is_signal_blocked(tid_i, kServiceSignal):
       row.status = SignalBlocked
       continue          # no signal sent, no bump
3. seq_i = g_sequence_num.load()
4. if rt_tgsigqueueinfo(tid_i, kServiceSignal, seq_i) != 0:
       row.status = ThreadExited or CaptureFailed
       ++g_sequence_num  # no signal arrived but bump anyway: cheap, matches sequential
       continue
5. if pending_idx >= 0:
       variant_walk_snapshot(pending_seq, &result.threads[pending_idx])
       pending_idx = -1
   # pipelined unwind: runs while tid_i's handler runs on the target thread
6. if not wait_on_pipe(remaining_ms_until(deadline_i))
       or g_data_ready_num.load() != seq_i:
       row.status = Timeout
       ++g_sequence_num  # drain late handler at seq_i
       continue
7. pending_idx = i
   pending_seq = seq_i
   ++g_sequence_num     # next iteration's seq differs by 1 -> opposite parity

final drain:
8. if pending_idx >= 0:
       variant_walk_snapshot(pending_seq, &result.threads[pending_idx])
```

Step 5 is the pipeline. Step 4 must run before step 5 so that the
handler's write to `g_snapshots[seq_i % 2]` is already in flight by
the time the coordinator reads `g_snapshots[pending_seq % 2]`. The
parities differ by invariant 3.

Step 7 must run before the next iteration's step 3 so the next
sequence read sees the bumped value. The bump must run before the
next iteration's step 4 so the new handler's entry check sees the
new sequence.

Handler body (variant's `capture_into_slot`):

```text
input:   ucontext_t* uc, StackCaptureSlot* slot
state:   g_snapshots[2]

1. seq = g_sequence_num.load()
   # caller has already checked seq against the payload; reload here
   # to pick the parity. Safe because g_sequence_num cannot move
   # forward until the coordinator's step 7.
2. snap = &g_snapshots[seq % 2]
3. memcpy(&snap->regs, uc, sizeof(ucontext_t))
4. rsp = uc->uc_mcontext.gregs[REG_RSP]
   snap->stack_base = 0
   snap->stack_size = 0
5. if rsp != 0 and page_is_mapped(rsp):
       cap = sizeof(snap->stack_bytes)
       local_iov  = {snap->stack_bytes, cap}
       remote_iov = {(void*)rsp, cap}
       n = syscall(SYS_process_vm_readv,
                   getpid(), &local_iov, 1, &remote_iov, 1, 0)
       if n > 0:
           snap->stack_base = rsp
           snap->stack_size = n
6. slot->status = OK
   slot->frame_count = 0
```

Step 1 reads `g_sequence_num` again inside the handler. The common
handler already validated the payload's sequence against
`g_sequence_num` at step 5 of `print_stack_signal_handler`. The
reload is for parity selection; it cannot read a different value
because invariant 4 keeps `g_sequence_num` fixed during the
handler's execution window.

Step 5 uses `process_vm_readv` instead of `memcpy` for ASAN
reasons; see Decision 6.

Coordinator-side walk (`variant_walk_snapshot`):

```text
input:   int seq, ThreadStackTrace* out
state:   g_snapshots[2], tls_active_snapshot

1. snap = &g_snapshots[seq % 2]
2. accessors = {access_reg, access_mem, find_proc_info,
                put_unwind_info, get_dyn_info_list_addr,
                access_fpreg, resume, get_proc_name}
3. as = unw_create_addr_space(&accessors, 0)
   if as == nullptr:
       out->status = CaptureFailed
       return
4. tls_active_snapshot = snap
5. unw_cursor_t cursor
   if unw_init_remote(&cursor, as, &snap->regs) != 0:
       tls_active_snapshot = nullptr
       unw_destroy_addr_space(as)
       out->status = CaptureFailed
       return
6. for i in 0 .. kMaxSignalFrames:
       if unw_get_reg(&cursor, UNW_REG_IP, &ip) != 0: break
       if ip == 0: break
       out->frames.push_back(pc_to_frame(ip))
       if unw_step(&cursor) <= 0: break
7. tls_active_snapshot = nullptr
8. unw_destroy_addr_space(as)
9. out->status = OK
```

`access_reg` reads register values from the saved
`ucontext_t.uc_mcontext.gregs` — the `arg` libunwind passes to the
accessor is `&snap->regs`. `access_mem` serves stack words from
`snap->stack_bytes` for in-window addresses and falls through to a
live in-process read (mincore-guarded) for non-stack addresses
like eh_frame / unwind tables / DSO data. Live reads are safe in
the coordinator because the coordinator is not a signal handler.

For in-stack addresses that fall above the captured RSP but
outside the snapshot tail (the stack memory the target thread
has mutated since the snapshot), `access_mem` returns
`-UNW_EINVAL`. libunwind reads that as "memory access failed",
stops the walk, and reports the frames it has. Clean truncation
at the snapshot boundary.

## Decisions

1. **Handler does no unwinder.** Signal safety is a property of
   the handler body alone. The body is one structure copy plus
   one `process_vm_readv` syscall. The loader lock, jemalloc
   reentrancy, and DWARF chase questions move out of the handler
   entirely.

2. **No PHDR cache.** The handler does not call `dl_iterate_phdr`,
   so there is nothing to make async-signal-safe. The coordinator
   does call `dl_iterate_phdr` via libunwind remote, but the
   coordinator is a request thread, not a signal handler. Taking
   the loader lock there is allowed. Pipelining hides the
   per-thread cost behind the next thread's handler latency.

3. **Coordinator pipelining at depth 1.** The expensive coordinator
   step is the libunwind walk plus `pc_to_frame` calls. Most of
   that cost is loader-lock contention inside `dl_iterate_phdr`
   (no PHDR override here). By sending the next signal first and
   unwinding the previous snapshot afterward, the walk overlaps
   with the next handler's run time. Depth 1 is sufficient because
   the next signal blocks on `wait_on_pipe`, and the walk runs
   entirely inside that window.

4. **Libunwind remote mode against the snapshot.**
   `unw_create_addr_space` with custom accessors, `unw_init_remote`
   seeded from the captured `ucontext_t`, walk via `unw_step` +
   `unw_get_reg(UNW_REG_IP, ...)`. The accessors read register
   values from the saved registers and stack words from the
   snapshot bytes. DWARF lookups (`find_proc_info`) delegate to
   the exported `_Ux86_64_dwarf_find_proc_info` helper, which
   internally walks `dl_iterate_phdr` and parses
   `.eh_frame_hdr` — safe to do in the coordinator's request
   thread.

5. **Snapshot ring of two, keyed by parity.** The handler writes
   `g_snapshots[seq % 2]`. Adjacent sent sequences differ by 1,
   so adjacent handlers write opposite-parity buffers. The
   coordinator reads the pending parity while the next handler
   writes the other. No write-write race; no read-write race.

6. **`process_vm_readv` for the stack copy.** Under ASAN every
   cross-redzone stack read trips the stack-buffer-underflow
   check. The target thread's local variables sit between
   compiler-inserted redzones; the snapshot spans them by design.
   Doris's vendored `inline_memcpy` is built with ASAN
   instrumentation regardless of the caller's attribute, so
   `no_sanitize("address")` alone does not cover the memcpy
   interceptor. `process_vm_readv` does the copy entirely in the
   kernel. The kernel checks per-page that the source is readable,
   so a guard page mid-copy returns a short read instead of
   `SIGSEGV`.

7. **Variant-local snapshot store, not slot extension.** The
   architecture's `StackCaptureSlot` carries PCs. The snapshot's
   `ucontext_t` plus stack bytes do not belong there. The variant
   adds `g_snapshots` in its own TU. Single-phase variants pay
   nothing.

8. **`access_mem` fails closed for in-stack addresses outside the
   snapshot.** An address at or above the captured RSP that falls
   outside the captured tail is a stack address whose live value
   the target thread has mutated since the snapshot. Reading it
   would serve libunwind a frame inconsistent with the captured
   words and break `unw_step` non-determinism. Returning
   `-UNW_EINVAL` makes libunwind stop the walk and report the
   frames it has. Clean truncation at the snapshot boundary.

9. **TLS hand-off for the active snapshot.** libunwind passes one
   `void* arg` to every accessor. The variant uses that slot for
   the `ucontext_t` pointer that `access_reg` needs.
   `access_mem` needs the snapshot pointer too, for the
   stack-window check. The coordinator sets
   `tls_active_snapshot` immediately before `unw_init_remote`
   and clears it after `unw_destroy_addr_space`. `access_mem`
   reads it. Variant-TU-local.

10. **`__attribute__((no_sanitize("address")))` on
    `capture_into_slot`.** The body's `ucontext_t` structure copy
    would otherwise pass through ASAN's memcpy interceptor.
    `process_vm_readv` covers the stack copy already; the
    attribute is a cheap defense for the rest of the body. The
    common handler stays fully instrumented.

11. **`page_is_mapped` gate on the first stack page.** A target
    thread parked just above a guard page would otherwise have
    `process_vm_readv` return `EFAULT` for the whole call. The
    gate distinguishes "no stack to capture" (return cleanly with
    `stack_size = 0`) from "stack present but partial". libunwind
    then either gets nothing back from `access_mem` (stops at the
    first frame) or runs the walk until the captured tail ends.

12. **Link `libunwind-x86_64.a`; do NOT define `UNW_LOCAL_ONLY`.**
    The default `libunwind.a` archive that Doris already links is
    the local-only build. Its `_ULx86_64_init_remote` is a 6-byte
    stub returning `-UNW_EINVAL` (`mov $0xfffffff8, %eax; ret`) —
    `src/x86_64/Linit_remote.c` includes `Ginit_remote.c` with
    `UNW_LOCAL_ONLY` defined, which compiles the body out. The
    cursor-machinery for `unw_step` against a remote address space
    is the same way. So `nm` showing the `_UL` symbols exists does
    NOT mean the remote API works under those symbols.
    The real remote-mode implementation lives only in the per-arch
    archive `libunwind-x86_64.a` under the `_Ux86_64_*` prefix.
    The variant TU therefore does not define `UNW_LOCAL_ONLY` —
    `libunwind.h`'s macros resolve `unw_*` to the `_U` symbols —
    and `be/cmake/thirdparty.cmake` adds the per-arch archive to
    the link line. `ck-phdr-unwind` and `ob-kill60` keep
    `UNW_LOCAL_ONLY` because they only call the local API
    (`unw_init_local2`); the stubbed remote machinery is harmless
    for them.

13. **Pipelined coordinator body lives in `print_stack.cpp`,
    scoped to this variant's branch.** The variant patch replaces
    the body of `collect_print_stack`. The architecture stays
    sequential. Other variants apply different patches and keep
    the sequential body. Same isolation property `ob-kill60` uses
    when it modifies the common handler with phase-2 hooks.

14. **`kMaxSnapshotBytes`.** The per-slot stack buffer is a
    compile-time constant. The previous snapshot patch sized it
    at 1 MiB. The same number works here; revisit only if a real
    dump truncates frequently.

## Patch series

| # | Subject | Files |
|---|---|---|
| 0001 | `expose coordinator helpers from anonymous namespace` | `be/src/service/http/action/print_stack.cpp` — move helpers into a non-anonymous nested namespace (e.g., `doris::print_stack::detail`). Pure rename. |
| 0002 | `pipelined collector and variant_walk_snapshot hook` | `be/src/service/http/action/print_stack_capture.h` — declare `variant_walk_snapshot`. `be/src/service/http/action/print_stack.cpp` — replace `collect_print_stack` body with the state machine above. |
| 0003 | `variant TU: capture_into_slot, variant_walk_snapshot, snapshot ring` | `be/src/service/http/action/print_stack_snapshot_remote_unwind.cpp`. |
| 0004 | `link libunwind-x86_64.a for remote-mode API` | `be/cmake/thirdparty.cmake` — add `libunwind-x86_64.a` to thirdparty, gated on x86_64. |

## Files

| File | Role |
|---|---|
| `be/src/service/http/action/print_stack.cpp` | Patches 1 + 2: helpers exposed; `collect_print_stack` body replaced with the pipelined coordinator. |
| `be/src/service/http/action/print_stack_capture.h` | Patch 2: declare `variant_walk_snapshot`. |
| `be/src/service/http/action/print_stack_snapshot_remote_unwind.cpp` | Patch 3: variant TU. Defines `capture_into_slot`, `variant_walk_snapshot`, and `g_snapshots`. |
| `be/cmake/thirdparty.cmake` | Patch 4: link the per-arch `libunwind-x86_64.a` for the remote-mode entry points (see decision #12). |

## Runtime dlopen / dlclose compatibility

The variant ships no `dl_iterate_phdr` override. Every coordinator
`unw_step` takes the loader lock. A `dlopen` racing with the
coordinator's walk blocks until the dlopen finishes; a `dlclose`
during the walk blocks until the walk finishes. Both are correct
behaviors of the loader lock. No deadlock window.

The handler never reaches `dl_iterate_phdr`, so the loader-lock
question does not apply to the handler at all. This is the safest
handler profile of the four variants:

- `fp-walk`: handler reads RBP and stack words via `mincore`-guarded
  dereferences. No loader lock.
- `ck-phdr-unwind`: handler calls libunwind. Loader lock would
  block the handler; the PHDR override removes the lock.
- `ob-kill60`: handler calls libunwind. Loader lock can block the
  handler; the variant accepts the deadlock window.
- `snapshot-remote-unwind`: handler copies `ucontext_t` and stack
  bytes. No loader lock. No dereferences beyond the kernel-supplied
  signal context (`process_vm_readv` does the stack copy in the
  kernel). Coordinator takes the loader lock via libunwind, but in
  a request thread where the lock is allowed.
