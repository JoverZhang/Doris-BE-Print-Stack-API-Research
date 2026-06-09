---
title: OceanBase libunwind x86_64 path for Doris ck-phdr-unwind
created_at: 2026-06-09T12:23:12+08:00
workspace_root: /home/mira/lab/projects/Doris-BE-Print-Stack-API-Research
target_source_root: /home/mira/lab/projects/Doris-BE-Print-Stack-API-Research/.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind
target_branch: HEAD detached at v1.6.2
target_commit: b3ca1b59a795a617877c01fe5d299ab7a07ff29d
depth: standard
request: "$mira-code-research .mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind; analyze this project, specifically the x86 unwind path. I mainly want to know the relevant code paths used by this patch: patches/ck-phdr-unwind/0003-be-ck-phdr-unwind-libunwind-capture_into_slot.patch"
---

# OceanBase libunwind x86_64 path for Doris ck-phdr-unwind

## Question

Study the libunwind APIs directly called by the Doris `ck-phdr-unwind` patch
and map them to the corresponding code paths in the OceanBase reference source
and the nongnu libunwind v1.6.2 x86_64 implementation.

Key questions:

- How `UNW_LOCAL_ONLY` maps `unw_*` APIs to local `_ULx86_64_*` symbols.
- How `unw_init_local2(..., UNW_INIT_SIGNAL_FRAME)` initializes a signal
  `ucontext_t`.
- How `unw_get_reg(..., UNW_REG_IP)` and `unw_step()` read IP and advance
  stack frames on x86_64.
- Where the OceanBase `safe_backtrace()` call shape matches the Doris patch,
  and where it differs.

## Scope

In scope:

- Doris patch:
  `patches/ck-phdr-unwind/0003-be-ck-phdr-unwind-libunwind-capture_into_slot.patch`
- OceanBase upper call path:
  `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/*`
- OceanBase build/dependency declarations:
  `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/CMakeLists.txt`,
  `repos/source/oceanbase-v4.5.0_CE/deps/init/oceanbase.el8.x86_64.deps`
- libunwind implementation snapshot:
  `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind`

Out of scope:

- ClickHouse LLVM libunwind implementation.
- Doris thirdparty source build internals outside the cited patch.
- non-x86_64 architectures except as negative search space.
- OceanBase full `kill -60` protocol details beyond the call edge into
  `safe_backtrace()`.

Source acquisition:

- none. Existing local sources were used.
- Existing libunwind source root was verified as upstream
  `https://github.com/libunwind/libunwind.git`, tag `v1.6.2`, commit
  `b3ca1b59a795a617877c01fe5d299ab7a07ff29d`.
- Existing OceanBase source root was verified at
  `repos/source/oceanbase-v4.5.0_CE`, detached commit
  `0e8d5ad012baf0953b2032a35a88bdf8886e9a7a`.

## Executive Summary

- The direct Doris `ck-phdr-unwind` path is a local-only libunwind walk inside
  a signal handler: copy `ucontext_t` into `unw_context_t`, call
  `unw_init_local2(..., UNW_INIT_SIGNAL_FRAME)`, then loop over
  `unw_get_reg(UNW_REG_IP)` + `unw_step()`.
  Evidence: `patches/ck-phdr-unwind/0003-be-ck-phdr-unwind-libunwind-capture_into_slot.patch:46`,
  `patches/ck-phdr-unwind/0003-be-ck-phdr-unwind-libunwind-capture_into_slot.patch:67`,
  `patches/ck-phdr-unwind/0003-be-ck-phdr-unwind-libunwind-capture_into_slot.patch:71`,
  `patches/ck-phdr-unwind/0003-be-ck-phdr-unwind-libunwind-capture_into_slot.patch:81`,
  `patches/ck-phdr-unwind/0003-be-ck-phdr-unwind-libunwind-capture_into_slot.patch:85`.
- The upper OceanBase `safe_backtrace()` path uses the same family of nongnu
  libunwind local APIs, but it creates the current thread context with
  `unw_getcontext()` and calls `unw_init_local()`. It does not call
  `unw_init_local2()` on the `ucontext_t` passed as the third argument to a
  signal handler.
  Evidence: `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/ob_libunwind.c:15`,
  `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/ob_libunwind.c:30`,
  `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/ob_libunwind.c:61`,
  `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/ob_libunwind.c:70`,
  `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/ob_libunwind.c:87`.
- The core libunwind x86_64 path is: macro-map `unw_*` to `_ULx86_64_*`;
  `Ginit_local.c` selects `use_prev_instr`; `init.h` builds register
  locations from Linux `uc_mcontext.gregs`; `Gget_reg.c` returns the cached
  cursor IP directly for IP reads; `Gstep.c` tries `dwarf_step()` first, then
  falls back to signal-frame, PLT, and frame-chain handling when needed.
  Evidence: `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/include/libunwind-common.h.in:51`,
  `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/include/libunwind-common.h.in:242`,
  `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Ginit_local.c:64`,
  `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/init.h:31`,
  `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/mi/Gget_reg.c:34`,
  `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Gstep.c:73`.
- Safety boundary: libunwind man pages claim local `unw_init_local`,
  `unw_get_reg`, and `unw_step` are signal-safe, and tests cover both
  `unw_init_local2` signal contexts and async-signal basic unwinding. But the
  implementation still has first-use initialization, global/per-thread cache,
  mutex/signal-mask, and memory-validation behavior that must be considered
  before running it in a Doris signal handler.
  Evidence: `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/doc/unw_init_local.man:69`,
  `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/doc/unw_step.man:45`,
  `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/tests/Ltest-init-local-signal.c:26`,
  `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/include/libunwind_i.h:150`,
  `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Gglobal.c:77`.

## Evidence Map

| Claim | Classification | Evidence | Confidence |
|---|---|---|---|
| Doris patch defines `UNW_LOCAL_ONLY` before `<libunwind.h>` and uses local-only symbols. | direct / build-contract | `patches/ck-phdr-unwind/0003-be-ck-phdr-unwind-libunwind-capture_into_slot.patch:46`, `patches/ck-phdr-unwind/0003-be-ck-phdr-unwind-libunwind-capture_into_slot.patch:49`, `patches/ck-phdr-unwind/0003-be-ck-phdr-unwind-libunwind-capture_into_slot.patch:51` | high |
| Doris patch seeds the cursor from an interrupted thread `ucontext_t` with `UNW_INIT_SIGNAL_FRAME`. | direct | `patches/ck-phdr-unwind/0003-be-ck-phdr-unwind-libunwind-capture_into_slot.patch:67`, `patches/ck-phdr-unwind/0003-be-ck-phdr-unwind-libunwind-capture_into_slot.patch:68`, `patches/ck-phdr-unwind/0003-be-ck-phdr-unwind-libunwind-capture_into_slot.patch:71` | high |
| Doris patch captures IP then advances by `unw_step()` until cap or failure. | direct | `patches/ck-phdr-unwind/0003-be-ck-phdr-unwind-libunwind-capture_into_slot.patch:75`, `patches/ck-phdr-unwind/0003-be-ck-phdr-unwind-libunwind-capture_into_slot.patch:81`, `patches/ck-phdr-unwind/0003-be-ck-phdr-unwind-libunwind-capture_into_slot.patch:85` | high |
| OB `safe_backtrace()` is x86_64-only and uses `UNW_LOCAL_ONLY`. | direct / guard | `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/ob_libunwind.c:13`, `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/ob_libunwind.c:15`, `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/ob_libunwind.c:16` | high |
| OB upper wrapper uses `unw_getcontext()` + `unw_init_local()`, not `unw_init_local2()`. | direct | `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/ob_libunwind.c:26`, `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/ob_libunwind.c:30`, `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/ob_libunwind.c:61`; searched no hit for `unw_init_local2|UNW_INIT_SIGNAL_FRAME` in `repos/source/oceanbase-v4.5.0_CE` | high |
| OB records IP as `uip - 1` for normal frames and does not subtract for signal frames. | direct | `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/ob_libunwind.c:90`, `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/ob_libunwind.c:94`, `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/ob_libunwind.c:97` | high |
| OB links static libunwind only for x86_64 and pins devdeps libunwind 1.6.2. | build-contract | `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/CMakeLists.txt:261`, `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/CMakeLists.txt:299`, `repos/source/oceanbase-v4.5.0_CE/deps/init/oceanbase.el8.x86_64.deps:17` | high |
| `UNW_LOCAL_ONLY` changes `UNW_PREFIX` from `_Ux86_64_` to `_ULx86_64_`; `unw_init_local2`, `unw_step`, and `unw_get_reg` are macro-remapped through `UNW_OBJ`. | dependency | `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/include/libunwind-common.h.in:48`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/include/libunwind-common.h.in:51`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/include/libunwind-common.h.in:242`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/include/libunwind-common.h.in:244`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/include/libunwind-common.h.in:250` | high |
| x86_64 `unw_context_t` is directly `ucontext_t`; `UNW_REG_IP` maps to `UNW_X86_64_RIP`. | dependency | `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/include/libunwind-common.h.in:84`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/include/libunwind-common.h.in:121`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/include/libunwind-x86_64.h:102`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/include/libunwind-x86_64.h:118` | high |
| `unw_init_local2(..., UNW_INIT_SIGNAL_FRAME)` sets `use_prev_instr=0`; regular init sets it to 1. | dependency | `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Ginit_local.c:58`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Ginit_local.c:64`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Ginit_local.c:70`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/init.h:81` | high |
| x86_64 local init takes register locations from Linux `uc_mcontext.gregs`, reads RIP into cursor `ip`, and initializes CFA from RSP. | dependency | `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/init.h:31`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/init.h:65`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/init.h:67`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/init.h:71` | high |
| `unw_get_reg(UNW_REG_IP)` returns cached `c->dwarf.ip` directly. | dependency | `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/mi/Gget_reg.c:29`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/mi/Gget_reg.c:34`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/mi/Gget_reg.c:36` | high |
| `unw_step()` first calls `dwarf_step()`; fallback handles signal frame, PLT, and frame-chain cases. | dependency | `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Gstep.c:73`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Gstep.c:75`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Gstep.c:101`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Gstep.c:125`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Gstep.c:134`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Gstep.c:144` | high |
| The DWARF parser uses current IP for signal frames and previous IP for normal call frames. | dependency | `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/dwarf/Gparser.c:432`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/dwarf/Gparser.c:438`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/dwarf/Gparser.c:444`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/dwarf/Gparser.c:535` | high |
| First libunwind use can initialize global state and memory validation under a mutex. | prerequisite / safety-contract | `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Ginit_local.c:47`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Gglobal.c:77`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Gglobal.c:84`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Gglobal.c:94`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Gglobal.c:97` | high |

## Discovery Matrix

| Axis | Seeds / Commands | Findings | Result |
|---|---|---|---|
| Runtime call path | `rg -n "UNW_LOCAL_ONLY|unw_init_local2|UNW_INIT_SIGNAL_FRAME|unw_get_reg|unw_step" patches/ck-phdr-unwind/0003...` | Doris patch path: define local-only, copy signal `ucontext_t`, init with `UNW_INIT_SIGNAL_FRAME`, read IP, step cursor. Evidence: `patches/ck-phdr-unwind/0003-be-ck-phdr-unwind-libunwind-capture_into_slot.patch:49`, `patches/ck-phdr-unwind/0003-be-ck-phdr-unwind-libunwind-capture_into_slot.patch:68`, `patches/ck-phdr-unwind/0003-be-ck-phdr-unwind-libunwind-capture_into_slot.patch:71`, `patches/ck-phdr-unwind/0003-be-ck-phdr-unwind-libunwind-capture_into_slot.patch:81`, `patches/ck-phdr-unwind/0003-be-ck-phdr-unwind-libunwind-capture_into_slot.patch:85`. | direct |
| Runtime call path | `rg -n "safe_backtrace|get_stack_trace_inplace|get_frame_info" repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal` | OB path: `safe_backtrace()` -> `unw_getcontext()` -> `get_stack_trace_inplace()` -> `unw_init_local()` -> `unw_step()` -> `unw_get_reg()`. Evidence: `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/ob_libunwind.c:26`, `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/ob_libunwind.c:30`, `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/ob_libunwind.c:55`, `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/ob_libunwind.c:61`, `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/ob_libunwind.c:70`, `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/ob_libunwind.c:87`. | adjacent/direct |
| Startup prerequisites | `rg -n "tdep_init_done|tdep_init|dwarf_init|tdep_init_mem_validate|local_addr_space_init" libunwind/src/x86_64` | `unw_init_local_common()` calls `tdep_init()` on first use; `tdep_init()` locks, initializes `mi`, DWARF, mem validation, and local address space. Evidence: `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Ginit_local.c:47`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Gglobal.c:77`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Gglobal.c:84`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Gglobal.c:92`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Gglobal.c:94`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Gglobal.c:97`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Gglobal.c:99`. | prerequisite |
| Build/link/compiler contract | `rg -n "libunwind|devdeps-libunwind|ARCHITECTURE" repos/source/oceanbase-v4.5.0_CE/deps` | OB links `${DEP_DIR}/lib/libunwind.a` under x86_64 and package deps pin `devdeps-libunwind-static-1.6.2...x86_64.rpm`. Evidence: `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/CMakeLists.txt:261`, `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/CMakeLists.txt:299`, `repos/source/oceanbase-v4.5.0_CE/deps/init/oceanbase.el8.x86_64.deps:17`. | build-contract |
| Build/link/compiler contract | `rg -n "TARGET_AMD64|libunwind_la_SOURCES_x86_64|libunwind_remote" libunwind/CMakeLists.txt libunwind/src/CMakeLists.txt` | The local snapshot has an x86_64 source list for local-only objects and a generic/remote x86_64 source list. Its top-level CMake is Visual-Studio-specific; do not infer Linux OB build behavior from that CMake alone. Evidence: `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/CMakeLists.txt:12`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/CMakeLists.txt:92`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/CMakeLists.txt:247`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/CMakeLists.txt:260`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/CMakeLists.txt:321`. | build-contract |
| Platform/feature gates | `rg -n "__x86_64__|UNW_TARGET_X86_64|__linux__|UNW_LOCAL_ONLY"` | OB wrapper is guarded by `__x86_64__`; libunwind header selects x86_64 by `__x86_64__`; x86_64 local init has Linux-specific fast register locations. Evidence: `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/ob_libunwind.c:13`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/include/libunwind.h.in:24`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/include/libunwind-x86_64.h:39`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/init.h:31`. | guard |
| Signal/concurrency safety | `rg -n "signal handler|safe|pthread_mutex|lock_acquire|caching_policy|CONSERVATIVE_CHECKS|validate_mem"` | Docs claim signal safety for local `unw_init_local`, `unw_step`, and `unw_get_reg`; implementation includes mutex-backed initialization, cache locking, and optional memory validation in fallback. Evidence: `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/doc/unw_init_local.man:83`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/doc/unw_step.man:45`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/doc/unw_get_reg.man:68`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/include/libunwind_i.h:150`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/dwarf/Gparser.c:595`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Gstep.c:117`. | safety-contract |
| Dependency/local patch surface | `git -C libunwind describe --tags --always --dirty`; `rg -n "UNW_OBJ|UNW_PREFIX|unw_init_local2|dwarf_step"` | The used dependency evidence is upstream nongnu libunwind `v1.6.2`; no OB-local libunwind source patch surface was found in this snapshot. Symbol mapping and implementations are in upstream files. Evidence: `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/include/libunwind-common.h.in:51`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Ginit_local.c:64`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Gstep.c:57`. | dependency |
| Tests/config/docs | `rg -n "Ltest-init-local-signal|test-async-sig|unw_init_local2|async-signal" libunwind/tests libunwind/doc` | `Ltest-init-local-signal.c` tests signal `ucontext` with `unw_init_local2`; `test-async-sig.c` tests repeated basic unwinding from a signal handler; docs describe signal-frame init. Evidence: `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/tests/Ltest-init-local-signal.c:26`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/tests/Ltest-init-local-signal.c:33`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/tests/test-async-sig.c:24`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/tests/test-async-sig.c:82`, `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/doc/unw_init_local.man:69`. | test-proof/config-doc |
| Negative search space | `rg -n "unw_init_local2|UNW_INIT_SIGNAL_FRAME" repos/source/oceanbase-v4.5.0_CE --glob '!deps/3rd/**' --glob '!build/**'` | No hits. OB upper source uses `unw_getcontext()` + `unw_init_local()`; the signal-frame variant exists in libunwind and its tests, not OB wrapper code. | searched-no-hit |
| Negative search space | `rg -n "libunwind" repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal` | Only `ob_libunwind.c`, `ob_libunwind.h`, and callers in signal utilities/processors/handlers are relevant; unrelated x86 files under codecs/compression were excluded after reading search context. | searched-no-hit / excluded |

## Implementation Path

1. `patches/ck-phdr-unwind/0003-be-ck-phdr-unwind-libunwind-capture_into_slot.patch:49` -
   Doris variant defines `UNW_LOCAL_ONLY` before including libunwind.
2. `patches/ck-phdr-unwind/0003-be-ck-phdr-unwind-libunwind-capture_into_slot.patch:67` -
   Doris `walk_signal_frame()` receives the interrupted thread's
   `ucontext_t`.
3. `patches/ck-phdr-unwind/0003-be-ck-phdr-unwind-libunwind-capture_into_slot.patch:68` -
   Doris copies the `ucontext_t` bytes into `unw_context_t`.
4. `patches/ck-phdr-unwind/0003-be-ck-phdr-unwind-libunwind-capture_into_slot.patch:71` -
   Doris starts the unwind with `unw_init_local2(...,
   UNW_INIT_SIGNAL_FRAME)`.
5. `patches/ck-phdr-unwind/0003-be-ck-phdr-unwind-libunwind-capture_into_slot.patch:81` -
   Doris reads `UNW_REG_IP` from the cursor into output slots.
6. `patches/ck-phdr-unwind/0003-be-ck-phdr-unwind-libunwind-capture_into_slot.patch:85` -
   Doris advances with `unw_step()` until no more frames or failure.
7. `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/include/libunwind-common.h.in:51` -
   `UNW_LOCAL_ONLY` changes `UNW_PREFIX` to `_UL<target>_`.
8. `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/include/libunwind-common.h.in:242` -
   `unw_init_local2` macro expands through `UNW_OBJ(init_local2)`.
9. `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/include/libunwind-common.h.in:244` -
   `unw_step` expands through `UNW_OBJ(step)`.
10. `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/include/libunwind-common.h.in:250` -
   `unw_get_reg` expands through `UNW_OBJ(get_reg)`.
11. `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/include/libunwind-x86_64.h:39` -
   x86_64 header sets `UNW_TARGET x86_64`.
12. `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/include/libunwind-x86_64.h:102` -
   `UNW_TDEP_IP` is `UNW_X86_64_RIP`.
13. `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/include/libunwind-x86_64.h:118` -
   x86_64 uses `ucontext_t` as `unw_tdep_context_t`.
14. `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Linit_local.c:1` -
   local-only object wrapper defines `UNW_LOCAL_ONLY` and includes
   `Ginit_local.c`, so public source names compile into `_ULx86_64_*`.
15. `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Ginit_local.c:64` -
   x86_64 implements `unw_init_local2`.
16. `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Ginit_local.c:70` -
   `UNW_INIT_SIGNAL_FRAME` selects `use_prev_instr=0`.
17. `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/init.h:31` -
   Linux local init maps registers directly to `uc_mcontext.gregs`.
18. `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/init.h:65` -
   RIP location is initialized from the saved context.
19. `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/init.h:67` -
   initial cursor IP is read from RIP.
20. `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/init.h:81` -
   `use_prev_instr` is stored in the DWARF cursor.
21. `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/mi/Gget_reg.c:34` -
   `UNW_REG_IP` returns cached cursor IP without a register callback.
22. `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Gstep.c:75` -
   `unw_step()` first tries `dwarf_step()`.
23. `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/dwarf/Gparser.c:444` -
   normal frames back up IP by one instruction when `use_prev_instr` is set.
24. `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/dwarf/Gparser.c:537` -
   FDE program execution uses `ip - c->use_prev_instr`.
25. `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/dwarf/Gparser.c:968` -
   `dwarf_step()` finds register state and applies it.
26. `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/dwarf/Gparser.c:885` -
   applying state reads the return address location and updates cursor IP.
27. `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Gstep.c:125` -
   only if DWARF lookup fails does x86_64 try the special signal-frame
   fallback.
28. `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Gos-linux.c:80` -
   `unw_is_signal_frame()` reports whether x86_64 cursor has signal-frame
   format.

## Preconditions And Contracts

Startup prerequisites:

- `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Ginit_local.c:47` -
  first local initialization checks `tdep_init_done` and calls `tdep_init()`.
- `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Gglobal.c:84` -
  `tdep_init()` masks signals and takes `x86_64_lock`.
- `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Gglobal.c:92` -
  `mi_init()` runs during first initialization.
- `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Gglobal.c:94` -
  `dwarf_init()` runs during first initialization.
- `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Gglobal.c:97` -
  local builds initialize memory validation before marking init done.

Build/link/compiler prerequisites:

- `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/CMakeLists.txt:261` -
  OB open-source link set includes `${DEP_DIR}/lib/libunwind.a` only when
  `ARCHITECTURE == x86_64`.
- `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/CMakeLists.txt:299` -
  OB non-open-source branch has the same x86_64 libunwind link condition.
- `repos/source/oceanbase-v4.5.0_CE/deps/init/oceanbase.el8.x86_64.deps:17` -
  x86_64 dependency list pins `devdeps-libunwind-static-1.6.2`.
- `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/include/libunwind.h.in:24` -
  generated `<libunwind.h>` includes `libunwind-x86_64.h` when
  `__x86_64__` is defined.
- `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/CMakeLists.txt:247` -
  local-only x86_64 source list includes `L*` wrappers.
- `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/CMakeLists.txt:260` -
  generic/remote x86_64 source list includes `G*` implementations.

Runtime guards:

- `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/ob_libunwind.c:13` -
  OB `safe_backtrace()` implementation is compiled only for `__x86_64__`.
- `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/ob_signal_processor.cpp:62` -
  OB signal processor calls `safe_backtrace()` only under `__x86_64__`.
- `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/ob_signal_handlers.cpp:211` -
  OB coredump path calls `safe_backtrace()` only under `__x86_64__`.
- `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/ob_signal_handlers.cpp:47` -
  OB installs handlers for `SIGURG`.
- `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/ob_signal_struct.cpp:25` -
  OB defines `MP_SIG = SIGURG`.

Safety contracts:

- `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/doc/unw_init_local.man:83` -
  libunwind docs state `unw_init_local()` is thread-safe and signal-handler
  safe.
- `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/doc/unw_step.man:45` -
  docs state `unw_step()` is thread-safe and signal-handler safe for a local
  address-space cursor.
- `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/doc/unw_get_reg.man:68` -
  docs state `unw_get_reg()` is signal-handler safe.
- `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/include/libunwind_i.h:150` -
  internal locking may call pthread mutex routines when libpthread is linked.
- `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/dwarf/Gparser.c:595` -
  DWARF register-state cache can return a global cache requiring lock
  acquisition.
- `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Gstep.c:117` -
  fallback path validates addresses before dereferencing after DWARF failure.
- `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Ginit.c:313` -
  memory access callback can dereference local memory directly when validation
  is not requested.

## Related But Excluded

| Candidate | Why Related | Why Excluded |
|---|---|---|
| `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/ob_signal_worker.cpp:309` | This sends `MP_SIG` to a target thread in the OB `kill -60` protocol. | It is the signal-delivery protocol, not the libunwind x86_64 API implementation asked here. |
| `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/ob_signal_handlers.cpp:109` | The handler dispatches `MP_SIG` requests and calls the registered handler. | It is the upper signal protocol. The libunwind edge is in `ObSigBTOnlyProcessor::prepare()` and `safe_backtrace()`. |
| `repos/source/oceanbase-v4.5.0_CE/deps/oblib/src/lib/signal/ob_signal_handlers.cpp:55` | The script uses external `obstack` for a different stack dump path. | It is an external tool path, not `safe_backtrace()` or libunwind. |
| `.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/src/x86_64/Gtrace.c:382` | libunwind has a fast trace helper using `unw_getcontext`, `unw_init_local`, `unw_step`, and `unw_get_reg`. | Doris patch does not call `unw_backtrace()` or `tdep_trace()`; it manually walks cursor frames. |
| `patches/ob-kill60/0002-be-ob-kill60-libunwind-capture_into_slot-phase-2-hoo.patch:110` | Doris `ob-kill60` variant uses the same `unw_init_local2(..., UNW_INIT_SIGNAL_FRAME)` shape as `ck-phdr-unwind`. | User asked for the `ck-phdr-unwind` patch; this is useful adjacent confirmation but not the main patch under study. |

## Open Questions

- Inference: Doris thirdparty libunwind likely has the same nongnu v1.6.2
  local-only symbol behavior as the OB pinned package, because the Doris patch
  comment says the archive exposes `_ULx86_64_*` and the libunwind source shows
  exactly that macro mapping. This report did not inspect Doris built archives
  with `nm`; doing so would confirm the exact linked objects.
- The libunwind snapshot used here is upstream v1.6.2 source. OB build evidence
  shows a static RPM package with the same version, but does not prove package
  contents are byte-identical to the source snapshot. RPM source/package
  inspection would resolve that if exact package provenance matters.
- The report did not run Doris or OB tests. It is a source-path analysis, not a
  runtime acceptance result.

## Validation Checklist

- [x] Every cited file exists.
- [x] Every cited line exists.
- [x] Every major claim has evidence or is marked inference.
- [x] Every discovery matrix axis has findings or an explicit searched-no-hit row.
- [x] External source actions are recorded with destination and commit/tag.
