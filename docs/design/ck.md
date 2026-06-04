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

3. **Defense-in-depth gate.** `capture_into_slot` returns `CaptureFailed`
   with zero frames if `hasPHDRCache()` is false. Reason: a missing cache
   would route `dl_iterate_phdr` to the libc fallback, which takes the
   loader lock and is not async-signal-safe.

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
   instead. The build helper verifies `backtrace_method = 'libunwind'` in
   `config.log` and fails the build on mismatch.

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

#include "common/phdr_cache.h"
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

// Reason: variant capture. Body runs inside the signal handler.
// Spec: docs/architecture.md "Layer 3d"; docs/design/ck.md "Workflow".
void capture_into_slot(const ucontext_t& uc, StackCaptureSlot* out) {
    // 1. Default to failure; success path overwrites both fields.
    out->status = ThreadStackStatus::CaptureFailed;
    out->frame_count = 0;

    // 2. Refuse to unwind without the PHDR cache.
    if (!hasPHDRCache()) {
        return;
    }

    // 3. Walk the interrupted chain.
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
# build helper writes the archive to the install prefix below; running
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
2. If `!hasPHDRCache()`, return.
3. Copy `uc` into a local `unw_context_t`. Call
   `unw_init_local2(&cursor, &ctx, UNW_INIT_SIGNAL_FRAME)`. On non-zero
   return, return with the default failure fields.
4. Loop until `unw_step(&cursor) <= 0` or `n == kMaxSignalFrames`. Each
   iteration reads `UNW_REG_IP` and writes `out->pcs[n++]`. Stop on a
   zero IP or a `unw_get_reg` error.
5. Set `out->frame_count = n` and `out->status = OK`.
