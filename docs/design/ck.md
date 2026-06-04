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

6. **Jemalloc rebuilt with libunwind backtracer.** Patch
   `thirdparty/build-thirdparty.sh build_jemalloc_doris()` to pass
   `--enable-prof-libunwind` to the existing configure invocation.
   Reason: jemalloc's default heap-profile backtracer uses libgcc's
   `_Unwind_Backtrace`, which calls `_Unwind_Find_FDE` and re-enters
   `dl_iterate_phdr`. With the override active and profiling on, that
   re-entry deadlocks against jemalloc's internal locks. The
   `--enable-prof-libunwind` build makes jemalloc call `unw_backtrace`
   instead. `CPPFLAGS`/`LDFLAGS` point detection at the thirdparty
   libunwind; `LIBS=-llzma` is required because that libunwind is
   built with `-llzma` (see `build_libunwind`) and autoconf's
   `AC_CHECK_LIB` appends LIBS after `-lunwind`. The patched function
   also verifies `prof-libunwind : 1` in `config.log` (jemalloc 5.3.0
   records the backtracer choice as one of three boolean `result:`
   lines, not as a `backtrace_method` string) and aborts on mismatch
   (jemalloc/jemalloc#2504 — detection can silently fall back to
   libgcc). The rebuild writes to
   `${DORIS_THIRDPARTY}/installed/lib/libjemalloc_doris.a`, exactly
   where CMake's existing `add_thirdparty(jemalloc LIBNAME ...)`
   already looks; no `be/cmake/thirdparty.cmake` swap is needed.

## Files

| File | Role |
|---|---|
| `be/src/common/phdr_cache.cpp` | `dl_iterate_phdr` override; `updatePHDRCache`; `hasPHDRCache`. |
| `be/src/service/doris_main.cpp` | `updatePHDRCache()` call before `BackendOptions::init`. |
| `be/src/service/http/action/print_stack_ck_phdr_unwind.cpp` | `capture_into_slot` definition. TU-local `walk_signal_frame` helper. |
| `thirdparty/build-thirdparty.sh` | `build_jemalloc_doris()`: add `--enable-prof-libunwind` (+ `CPPFLAGS`/`LDFLAGS`/`LIBS` for libunwind detection); verify `prof-libunwind : 1` in `config.log` and abort on mismatch. |

The harness wrapper `scripts/phase2/phase2-jemalloc.sh`
(outside the Doris worktree) ensures the jemalloc source is unpacked
in `${TP_SOURCE_DIR}` and invokes `build-thirdparty.sh jemalloc_doris`
with `TP_DIR=${DORIS_THIRDPARTY}`. Idempotent: skips when the source
tree's `config.log` already records `prof-libunwind : 1`. The rebuild
writes `libjemalloc_doris.a` directly to
`${DORIS_THIRDPARTY}/installed/lib/`, which is where CMake's existing
`add_thirdparty(jemalloc LIBNAME "lib/libjemalloc_doris.a")` already
links from — no in-tree CMake path swap, no `.gitignore` change.

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

Jemalloc rebuild (`thirdparty/build-thirdparty.sh build_jemalloc_doris`):

```diff
-    CFLAGS="${cflags}" ../configure --prefix="${TP_INSTALL_DIR}" \
-        --with-install-suffix="_doris" "${WITH_LG_PAGE}" \
-        --with-jemalloc-prefix=je --enable-prof \
-        --disable-cxx --disable-libdl --disable-shared
+    CFLAGS="${cflags}" \
+        CPPFLAGS="-I${TP_INCLUDE_DIR}" \
+        LDFLAGS="-L${TP_LIB_DIR}" \
+        LIBS="-llzma" \
+        ../configure --prefix="${TP_INSTALL_DIR}" \
+        --with-install-suffix="_doris" "${WITH_LG_PAGE}" \
+        --with-jemalloc-prefix=je --enable-prof --enable-prof-libunwind \
+        --disable-cxx --disable-libdl --disable-shared
+
+    if ! grep -qE "result: prof-libunwind +: 1$" config.log; then
+        echo "ERROR: prof-libunwind != 1 in config.log;" \
+             "libunwind detection failed (jemalloc/jemalloc#2504)." >&2
+        grep -E "result: prof-(libunwind|libgcc|gcc) +:" config.log >&2 || true
+        exit 1
+    fi
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

| Site | Type | Status | Treatment |
|---|---|---|---|
| `be/src/util/libjvm_loader.cpp:91` (`dlopen(libjvm)`) | Real load on first JNI use | **TODO — deferred** | Call `updatePHDRCache()` after `LibJVMLoader::load` returns success. The only site that warrants intervention. Not yet implemented in this patch series; track as follow-up. |
| `be/src/util/libjvm_loader.cpp:92` (`dlclose(libjvm)`) | Destructor on shutdown | No treatment needed | Benign — the BE keeps the JVM for process lifetime; the destructor runs after the signal-trap subsystem is already down. |
| `be/src/runtime/user_function_cache.cpp:150` (`dynamic_open(nullptr, ...)`) | `dlopen(NULL, ...)` = self-handle | No treatment needed | No new DSO; the call returns a handle to the BE itself. PHDR cache unaffected. |
| `be/src/runtime/user_function_cache.cpp:472` (`dynamic_open(.so, ...)`) | Native `.so` UDF load via `LibType::SO` | **Deprecated — no treatment** | No frontend driver triggers `LibType::SO`. Java UDFs run as in-process JVM bytecode via JNI (`function_java_udf.cpp:111 call_long_method`); Python UDFs run out-of-process via `boost::process::child` over a Unix socket (`python_server.cpp:228 fork`). The only entry to `LibType::SO` is `_load_entry_from_lib` rehydrating `.so` files at startup, with no execution path calling into them. |
| `be/src/util/dynamic_util.cpp:54` (`dlclose`) | Generic unloader | **Deprecated — no treatment** | Reachable only via the deprecated native `.so` UDF path. |

**Net.** Java UDFs in Doris are *in-process* via an embedded JVM —
`libjvm_loader.cpp:91 dlopen(libjvm)` puts libjvm.so into the BE
address space, `jni-util.cpp:156 JNI_CreateJavaVM` initializes a JVM
inside the BE process, and `function_java_udf.cpp:111 call_long_method`
runs `UdfExecutor.evaluate` as Java bytecode in that same JVM. This
differs from ClickHouse, whose executable UDFs always fork through
`ShellCommand` and whose WebAssembly UDFs run in a sandbox; CK has no
embedded native runtime. Only Doris's Python UDFs are isolated like
CK's executable UDFs. The libjvm dlopen is the one site worth a hook;
everything else on the list is either harmless (self-handle, shutdown
destructor) or deprecated (native `.so` UDF).

**Known limitation of the libjvm hook.** Once the JVM is loaded,
libjvm.so can internally `dlopen` more native libraries on demand
(libhdfs JNI bindings, native parquet/orc accelerators, anything a
Java UDF jar pulls in via `System.loadLibrary`). Those dlopens go
through libc and never call back into `updatePHDRCache()`. A single
hook after `LibJVMLoader::load` catches the bulk JVM init dlopens;
lazy `System.loadLibrary` calls inside UDF code remain a hole. The
capture-time consequence is lossy unwinding through frames in those
libraries — not a crash. Accepted; full coverage would require
interposing `dlopen`/`dlclose` system-wide to maintain a latched
cache, which is out of scope for this variant.

**Decision (deferred).** Hook `updatePHDRCache()` immediately after
`LibJVMLoader::load` succeeds. Not in this patch series — track as
follow-up. The variant's existing tests pass without the hook because
the BE under test does not exercise JVM-mediated unwinding paths.
