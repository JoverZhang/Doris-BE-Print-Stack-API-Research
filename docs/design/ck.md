# ck-phdr-unwind Variant Design

> Owner: agent.
> Follow [writing-guidelines.md](../writing-guidelines.md) when you edit this file.
> Variant-specific design for `ck-phdr-unwind`. Layers and shared code live
> in [architecture.md](../architecture.md). This file covers only what this
> variant adds on top.

## Scope

The variant supplies Layer 3d and the infrastructure that lets libunwind run
inside the signal handler.

`unw_step` reaches `dl_iterate_phdr`. The libc version takes the loader
lock and is not async-signal-safe. The variant interposes a lock-free walk
over a cached PHDR list, populates the cache at startup, and rebuilds
jemalloc so its heap profiler does not deadlock against the override.

## Decisions

1. **Lock-free `dl_iterate_phdr` override.** Interpose libc `dl_iterate_phdr`
   with a lock-free walk over the cached PHDR list. The override lives in
   `be/src/common/phdr_cache.cpp`. Reason: a cache hit serves the callback
   without touching the loader lock, so the handler stays async-signal-safe.

2. **Populate the cache at startup.** Call `updatePHDRCache()` in
   `doris_main.cpp` before `BackendOptions::init`. The call runs before any
   BE worker thread exists, so every thread that can later run the handler
   sees a populated cache.

3. **No `hasPHDRCache()` gate in the unwind path.** `capture_into_slot`
   calls `unw_init_local2` + `unw_step` unconditionally. Reason: CK runs
   the same shape under TSan in CI
   (`tests/queries/0_stateless/03565_system_stack_trace_works.sh` carries
   no `no-tsan` tag) and `src/Storages/System/StorageSystemStackTrace.cpp`
   builds `StackTrace(signal_context)` — which goes to `unw_backtrace` —
   unconditionally. CK reserves `hasPHDRCache()` for the `trace_log`
   continuous sampler boot decision in `programs/server/Server.cpp:1339`,
   not the on-demand `system.stack_trace` handler. A gate at one capture
   site cannot meaningfully protect the process when exception unwinding,
   jemalloc backtracing, and other `dl_iterate_phdr` callers run
   unguarded; defense-in-depth there is theatre. Under TSan,
   `USE_PHDR_CACHE` is compile-guarded off so `dl_iterate_phdr` falls
   through to libc — CK has accepted this in production for years
   without deadlock evidence.

4. **Seed from the interrupted ucontext.** Initialize the unwind cursor
   with `unw_init_local2(&cursor, ctx, UNW_INIT_SIGNAL_FRAME)` where `ctx`
   is the saved `ucontext_t` the common handler passes in. Reason: CK's
   `unw_backtrace` seeds with `unw_getcontext`, which captures the
   handler's own frame, not the interrupted thread's. `UNW_INIT_SIGNAL_FRAME`
   tells libunwind the context came from a signal frame so the first IP
   read returns the interrupted PC.

5. **TU-scoped `UNW_LOCAL_ONLY`.** Define `UNW_LOCAL_ONLY` before
   `<libunwind.h>` in the variant TU. Reason: the Doris libunwind archive
   exposes only the local-only `_ULx86_64_*` symbols. Without the define,
   the include resolves to remote `_Ux86_64_*` symbols the archive does
   not export, and the BE fails to link.

6. **Jemalloc rebuilt with libunwind backtracer.** Doris BE links a
   `libjemalloc_doris.a` configured with `--enable-prof-libunwind`. Reason:
   jemalloc's default heap-profile backtracer uses libgcc's
   `_Unwind_Backtrace`, which calls `_Unwind_Find_FDE` and re-enters
   `dl_iterate_phdr`. With the override active and profiling on, that
   re-entry deadlocks against jemalloc's internal locks. The
   `--enable-prof-libunwind` build makes jemalloc call `unw_backtrace`
   instead. The build helper verifies `prof-libunwind     : 1` in
   `config.log` (jemalloc 5.3.0 records the backtracer choice as one of
   three boolean result lines, not as a `backtrace_method` string) and
   fails the build on mismatch (jemalloc/jemalloc#2504 — detection can
   silently fall back to libgcc).

## Files

| File | Role |
|---|---|
| `be/src/common/phdr_cache.cpp` | `dl_iterate_phdr` override; `updatePHDRCache`; `hasPHDRCache`. |
| `be/src/service/doris_main.cpp` | `updatePHDRCache()` call before `BackendOptions::init`. |
| `be/src/service/http/action/print_stack_ck_phdr_unwind.cpp` | `capture_into_slot` definition. TU-local `walk_signal_frame` helper. |
| `be/cmake/build-jemalloc-prof-libunwind.sh` | Fetch jemalloc, configure with `--enable-prof-libunwind`, build, install, verify the backtracer choice. |
| `be/cmake/thirdparty.cmake` | Link `libjemalloc_doris.a` from the locally-built install prefix. |

`be/src/service/CMakeLists.txt` already globs `*.cpp` recursively, so the
new TU links without a CMakeLists edit.

## Shape

PHDR override (`be/src/common/phdr_cache.cpp`):

```cpp
// Reason: ELF-interposes libc `dl_iterate_phdr` with a lock-free walk
// over the cached PHDRs. The handler-side `unw_step` reaches
// `dl_iterate_phdr`; the libc version takes the loader lock and is not
// async-signal-safe.
// Reference: <ck>/base/base/phdr_cache.cpp:57-75.
extern "C" int dl_iterate_phdr(
        int (*callback)(dl_phdr_info* info, size_t size, void* data),
        void* data) {
    // 1. Cache miss: fall through to the original libc function.
    // 2. Cache hit: iterate the cached entries with no lock.
}
```

Startup (`be/src/service/doris_main.cpp`):

```cpp
// Reason: populate the PHDR cache before any BE worker thread exists.
// Spec: docs/design/ck.md "Decisions".
updatePHDRCache();

if (!doris::BackendOptions::init()) {
    exit(-1);
}
```

Variant capture (`be/src/service/http/action/print_stack_ck_phdr_unwind.cpp`):

```cpp
// Reason: the Doris libunwind archive exposes only the local-only
// `_ULx86_64_*` symbols. The define remaps `<libunwind.h>` to those.
// Spec: docs/design/ck.md "Decisions".
#define UNW_LOCAL_ONLY

#include <libunwind.h>
#include <ucontext.h>

#include <cstring>

#include "service/http/action/print_stack_capture.h"
#include "service/http/action/print_stack_globals.h"

namespace doris::print_stack {
namespace {

// Reason: seed from the interrupted thread's saved context and walk
// the chain. `UNW_INIT_SIGNAL_FRAME` tells libunwind the context came
// from a signal handler so the first IP read returns the interrupted PC.
// Reference: <ck>/contrib/llvm-project/libunwind/src/libunwind.cpp:221-240
//   (CK's `unw_backtrace` — the same step loop, but seeded from
//   `unw_getcontext`).
size_t walk_signal_frame(const ucontext_t& uc, uintptr_t* out, size_t cap) {
    unw_context_t ctx;
    std::memcpy(&ctx, &uc, sizeof(ctx));

    unw_cursor_t cursor;
    if (unw_init_local2(&cursor, &ctx, UNW_INIT_SIGNAL_FRAME) != 0) {
        return 0;
    }

    size_t n = 0;
    do {
        if (n >= cap) {
            break;
        }
        unw_word_t ip = 0;
        if (unw_get_reg(&cursor, UNW_REG_IP, &ip) != 0 || ip == 0) {
            break;
        }
        out[n++] = static_cast<uintptr_t>(ip);
    } while (unw_step(&cursor) > 0);

    return n;
}

} // namespace

// Reason: variant capture. Body runs inside the signal handler. No
// `hasPHDRCache()` gate — see Decision 3.
// Spec: docs/architecture.md "Layer 3d"; docs/design/ck.md "Workflow".
// Reference: <ck>/src/Storages/System/StorageSystemStackTrace.cpp:163
//   (CK's handler builds `StackTrace(signal_context)` unconditionally).
void capture_into_slot(const ucontext_t& uc, StackCaptureSlot* out) {
    // 1. Default to failure; success path overwrites both fields.
    out->status = ThreadStackStatus::CaptureFailed;
    out->frame_count = 0;

    // 2. Walk the interrupted chain.
    out->frame_count = walk_signal_frame(uc, out->pcs.data(),
                                         kMaxSignalFrames);
    out->status = ThreadStackStatus::OK;
}

} // namespace doris::print_stack
```

Jemalloc swap (`be/cmake/thirdparty.cmake`):

```cmake
# Reason: link the locally-built jemalloc whose heap-profile backtracer
# uses `unw_backtrace` instead of libgcc's `_Unwind_Backtrace`. The
# build helper writes the archive to `be/.tmp/jemalloc-prof-libunwind/`
# (gitignored, survives `phase2-reset`); running
# `be/cmake/build-jemalloc-prof-libunwind.sh` is a prerequisite of the
# `cmake` configure step.
# Spec: docs/design/ck.md "Decisions".
add_library(jemalloc STATIC IMPORTED)
set_target_properties(jemalloc PROPERTIES
    IMPORTED_LOCATION
    "${CMAKE_SOURCE_DIR}/.tmp/jemalloc-prof-libunwind/install/lib/libjemalloc_doris.a")
```

## Workflow inside `capture_into_slot`

1. Set `out->status = CaptureFailed`, `out->frame_count = 0`.
2. Copy `uc` into a local `unw_context_t`. Call
   `unw_init_local2(&cursor, &ctx, UNW_INIT_SIGNAL_FRAME)`. On non-zero
   return, return with the default failure fields.
3. Loop until `unw_step(&cursor) <= 0` or `n == kMaxSignalFrames`. Each
   iteration reads `UNW_REG_IP` and writes `out->pcs[n++]`. Stop on a
   zero IP or a `unw_get_reg` error.
4. Set `out->frame_count = n` and `out->status = OK`.

## Runtime dlopen / dlclose compatibility

The lock-free `dl_iterate_phdr` override is global, so every
`dlopen`/`dlclose` after `updatePHDRCache()` runs makes the cache
stale: stale entries miss new libraries (lossy unwinding through their
frames) and dangling entries point into unmapped memory (handler reads
through freed PHDRs). CK avoids this by banning `dlopen` after startup;
Doris cannot, so the sites below need explicit treatment.

Inventory of in-process `dlopen`-family calls in `be/src/`:

| Site | Type | Treatment |
|---|---|---|
| `be/src/util/libjvm_loader.cpp:91` (`dlopen(libjvm)`) | Real load on first JNI use | Call `updatePHDRCache()` after `LibJVMLoader::load` returns success. Only real concern. |
| `be/src/util/libjvm_loader.cpp:92` (`dlclose(libjvm)`) | Destructor on shutdown | Benign in practice (BE keeps the JVM for process lifetime). Pin if explicit close paths emerge. |
| `be/src/runtime/user_function_cache.cpp:150` (`dynamic_open(nullptr, ...)`) | `dlopen(NULL, ...)` = self-handle | No new DSO; PHDR cache unaffected. Ignore. |
| `be/src/runtime/user_function_cache.cpp:472` (`dynamic_open(.so, ...)`) | Native `.so` UDF load via `LibType::SO` | Vestigial — no frontend UDF path triggers `LibType::SO`. Every modern UDF goes through `get_jarpath` (Java UDF via JVM) or `get_pypath` (Python UDF via out-of-process `python_server.py` subprocess). The only entry to `LibType::SO` is `_load_entry_from_lib` rehydrating `.so` files left in the local cache dir at startup, and no execution path calls into them. Negligible risk; leave untreated. |
| `be/src/util/dynamic_util.cpp:54` (`dlclose`) | Generic unloader | Reachable only via the vestigial `.so` UDF path. Negligible risk. |

Net: libjvm is the only real concern. Modern Doris UDFs run isolated
(JVM-mediated for Java; out-of-process subprocess for Python), matching
CK's isolation model in spirit. The native `.so` UDF path is dead code
in current deployments.

Decision: hook `updatePHDRCache()` immediately after
`LibJVMLoader::load` succeeds. The native `.so` UDF path is left as-is
until/unless a frontend driver for it returns.
