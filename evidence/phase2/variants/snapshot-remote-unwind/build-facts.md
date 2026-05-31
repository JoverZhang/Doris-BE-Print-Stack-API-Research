# snapshot-remote-unwind — Build Facts

Evidence that the build wired the load-bearing pieces the variant depends on.
Captured against `phase2/snapshot-remote-unwind` head `67043f78eed`, image
`docker.io/apache/doris:build-env-ldb-toolchain-latest` (`7b449a709746`).

## Pre-verify gate — libunwind remote symbols resolve

The brief's "Pre-Verify Gate" was the largest budget risk for this variant.
The thirdparty libunwind archive sometimes stubs the remote address-space
creation symbols; the brief required proving they link before any handler
work.

### Probe TU

A small driver was compiled in the build-env container; the source is
preserved here verbatim:

```cpp
#include <libunwind.h>
#include <stdio.h>

static int dummy_find_proc_info(unw_addr_space_t, unw_word_t,
                                unw_proc_info_t*, int, void*) { return -1; }
static void dummy_put_unwind_info(unw_addr_space_t, unw_proc_info_t*, void*) {}
static int dummy_get_dyn_info_list_addr(unw_addr_space_t, unw_word_t*,
                                        void*) { return -1; }
static int dummy_access_mem(unw_addr_space_t, unw_word_t, unw_word_t*, int,
                            void*) { return -1; }
static int dummy_access_reg(unw_addr_space_t, unw_regnum_t, unw_word_t*,
                            int, void*) { return -1; }
static int dummy_access_fpreg(unw_addr_space_t, unw_regnum_t,
                              unw_fpreg_t*, int, void*) { return -1; }
static int dummy_resume(unw_addr_space_t, unw_cursor_t*, void*) { return -1; }
static int dummy_get_proc_name(unw_addr_space_t, unw_word_t, char*, size_t,
                               unw_word_t*, void*) { return -1; }

int main() {
    unw_accessors_t accessors;
    accessors.find_proc_info = dummy_find_proc_info;
    accessors.put_unwind_info = dummy_put_unwind_info;
    accessors.get_dyn_info_list_addr = dummy_get_dyn_info_list_addr;
    accessors.access_mem = dummy_access_mem;
    accessors.access_reg = dummy_access_reg;
    accessors.access_fpreg = dummy_access_fpreg;
    accessors.resume = dummy_resume;
    accessors.get_proc_name = dummy_get_proc_name;

    unw_addr_space_t as = unw_create_addr_space(&accessors, 0);
    if (!as) {
        printf("unw_create_addr_space returned null\n");
        return 1;
    }
    unw_cursor_t cursor;
    int dummy = 0;
    int rc = unw_init_remote(&cursor, as, &dummy);
    printf("unw_init_remote rc=%d\n", rc);
    unw_destroy_addr_space(as);
    return 0;
}
```

### Symbol inventory inside the archive (`nm`)

The archive `lib/libunwind.a` is local-only (`_ULx86_64_*` symbols only); the
remote-API entry points (`_Ux86_64_create_addr_space`, `_Ux86_64_init_remote`,
`_Ux86_64_destroy_addr_space`) live in `lib/libunwind-x86_64.a` (a.k.a.
`lib/libunwind-generic.a`, the same archive via symlink). Confirmed:

```
$ nm /var/local/thirdparty/installed/lib/libunwind-x86_64.a | grep -E '_Ux86_64_(create_addr_space|init_remote|destroy_addr_space|dwarf_find_proc_info|dwarf_put_unwind_info)$' | sort -u
0000000000000000 T _Ux86_64_create_addr_space
0000000000000000 T _Ux86_64_destroy_addr_space
0000000000000000 T _Ux86_64_init_remote
0000000000000d70 T _Ux86_64_dwarf_find_proc_info
0000000000000ed0 T _Ux86_64_dwarf_put_unwind_info
```

The local-only archive in contrast:

```
$ nm /var/local/thirdparty/installed/lib/libunwind.a | grep "_x86_64_create_addr_space\|_x86_64_init_remote\|_x86_64_destroy_addr_space" | sort -u
0000000000000000 T _ULx86_64_create_addr_space
0000000000000000 T _ULx86_64_destroy_addr_space
0000000000000000 T _ULx86_64_init_remote
```

(`_UL*` not `_U*` — the LOCAL prefix.)

### Link command + outcome

The naive link command (`-lunwind` only) fails — the local-only archive does
not export the `_Ux86_64_*` remote symbols:

```
$ g++ -std=c++17 -I/var/local/thirdparty/installed/include probe.cpp \
       -o probe-out-default \
       -L/var/local/thirdparty/installed/lib -lunwind
ld.lld: error: undefined symbol: _Ux86_64_create_addr_space
ld.lld: error: undefined symbol: _Ux86_64_init_remote
ld.lld: error: undefined symbol: _Ux86_64_destroy_addr_space
```

Adding `-lunwind-x86_64` (which ships the remote symbols) AND `-llzma`
(satisfies `lzma_*` references inside `libunwind-x86_64.a`'s `elf64.o` for
XZ-compressed debug sections) succeeds:

```
$ g++ -std=c++17 -I/var/local/thirdparty/installed/include probe.cpp \
       -o probe-out-with-lzma \
       -L/var/local/thirdparty/installed/lib \
       -Wl,--start-group -lunwind-x86_64 -lunwind -llzma -Wl,--end-group
$ ./probe-out-with-lzma
unw_init_remote rc=-1
```

(`rc=-1` is expected: our dummy accessors return -1, which is the correct
"this accessor cannot answer" signal for libunwind. The linkage is what the
gate measures — the probe ran and exited cleanly.)

**Pre-verify gate: PASS.** Remote symbols resolve.

### Build-system wiring

Patch 0004 adds `add_thirdparty(libunwind_generic LIBNAME "lib64/libunwind-x86_64.a")`
to `be/cmake/thirdparty.cmake` and `libunwind_generic` to `DORIS_DEPENDENCIES`
in `be/CMakeLists.txt`. `liblzma.a` is already in `COMMON_THIRDPARTY` via the
pre-existing `add_thirdparty(lzma LIB64)` lower in the same file, so the
WL_START_GROUP wrapping around `DORIS_DEPENDENCIES` resolves the
`lzma_*` references cleanly. Confirmed at the binary level (test binary,
post-link):

```
$ nm be/ut_build_ASAN/test/doris_be_test | grep -E '_Ux86_64_(create_addr_space|init_remote|destroy_addr_space|dwarf_find_proc_info|dwarf_put_unwind_info)$' | sort
... T _Ux86_64_create_addr_space
... T _Ux86_64_destroy_addr_space
... T _Ux86_64_dwarf_find_proc_info
... T _Ux86_64_dwarf_put_unwind_info
... T _Ux86_64_init_remote
```

## PHDR cache active in the test binary

Same situation as ck-phdr-unwind / ob-kill60: the lock-free
`dl_iterate_phdr` override defined in `be/src/common/phdr_cache.cpp`
(uncommented by patch 0001) is exported as a weak global text symbol,
which interposes the libc version at link time:

```
$ nm be/ut_build_ASAN/test/doris_be_test | grep -E 'dl_iterate_phdr|updatePHDRCache|hasPHDRCache'
... T _Z12hasPHDRCachev
... T _Z15updatePHDRCachev
... T dl_iterate_phdr
```

The cache is populated by `be/test/testutil/run_all_tests.cpp:109`
(`updatePHDRCache();` called before `RUN_ALL_TESTS`), and by `doris_main`
between `MemInfo::debug_string` and `BackendOptions::init` (patch 0002).
This variant's collector includes a defense-in-depth `hasPHDRCache()`
guard before arming the slot — important because the coordinator's
`unw_step` reaches `dl_iterate_phdr` during eh_frame lookup; if it ever
fired, every test case 7-13 (real-collector cases) would report
`phdr_cache_missing`. Every case passes with frames, so the cache is
live during the dump path.

Note: in snapshot-remote-unwind the cache matters for the COORDINATOR
(not the handler) because the handler runs no libunwind. The
PHDR-cache override is still required because the coordinator runs in
a request thread with potentially-jemalloc-allocator-holding-locks-
beside-it; without the cache the per-DSO `dl_iterate_phdr` walk takes
the loader lock and serializes the whole many-thread dump.

## jemalloc — backtrace_method (Tier 2 prerequisite)

**Status this round: not built.** Same as ck-phdr-unwind / ob-kill60:
Tier 1 keeps profiling OFF, so the prebuilt thirdparty jemalloc
(libgcc backtracer) is safe under this round's gate. Patch 0004 ships
the reusable rebuild path with the variant-prefixed CMake flag
`SNAPSHOT_REMOTE_UNWIND_LOCAL_JEMALLOC`:

- `be/cmake/build-jemalloc-prof-libunwind.sh`: fetches jemalloc-5.3.0
  (matching `thirdparty/vars.sh JEMALLOC_VERSION`), configures it with
  `--enable-prof-libunwind` plus the same flags `thirdparty`'s
  `build_jemalloc_doris()` uses, writes the static archive under
  `.tmp/jemalloc-prof-libunwind/install/`. The script greps
  `config.log` for `^backtrace_method = 'libunwind'` and fails fast if
  libunwind detection silently fell back to libgcc
  (`jemalloc/jemalloc#2504`).

- `be/cmake/thirdparty.cmake`: the CMake option
  `SNAPSHOT_REMOTE_UNWIND_LOCAL_JEMALLOC` (default OFF) swaps the
  prebuilt `add_thirdparty(jemalloc)` for an IMPORTED static target
  pointing at the locally-built archive. ON requires the script to
  have run first; otherwise CMake errors with the exact command to run.

The exact `config.log` line that proves wiring:

```
backtrace_method = 'libunwind'
```

## process_vm_readv stack-byte copy

The handler captures the interrupted thread's stack bytes via
`syscall(SYS_process_vm_readv, ...)` (self → self) rather than a plain
`memcpy`. Two reasons (recorded here because the choice is a deviation
from the brief's "use mincore-gated memcpy" suggestion):

1. **ASAN false-positive.** Under ASAN, the target thread's stack
   contains compiler-inserted poison redzones (`f1` / `f3` shadow
   bytes) between local variables. An instrumented memcpy
   interceptor (Doris ships its own `inline_memcpy` in
   `be/src/glibc-compatibility/memcpy/memcpy_x86_64.cpp`, which is
   compiled with ASAN instrumentation just like everything else)
   reports every cross-redzone read as a stack-buffer-underflow.
   `__attribute__((no_sanitize("address")))` on the handler does
   NOT propagate to functions it calls, so the inline_memcpy still
   trips. `process_vm_readv` does the copy entirely in the kernel,
   so ASAN's userspace shadow has no place to intercept; the same
   trick perf and gdb use.

2. **Per-page safety.** The kernel checks per-page that the source
   is readable, so a guard page mid-copy returns a short read
   rather than SIGSEGV. This subsumes fp-walk's per-page mincore
   loop into the syscall itself.

The handler also pre-checks the first page via `mincore` before
calling `process_vm_readv`, as a fast-path reject for a target
thread whose RSP fell into an unmapped region — that pattern
mirrors fp-walk's RBP-page guard.

## Test stability ledger

| run | result | timing |
|---:|--|--|
| 1 | 14 / 14 pass | 2051 ms total |
| 2 | 14 / 14 pass | 2022 ms total |
| 3 | 14 / 14 pass | 2031 ms total |

The three-consecutive-pass requirement is met. `DumpLoopNoCrashNoStuck`
(case 13) sits at 5.8-5.9 s for 200 iterations (slower than ck-phdr-
unwind's ~940 ms because the coordinator's libunwind walk runs
post-handler and re-walks the snapshot for each iteration — but well
inside the 60-second wall-clock bound).

### Wider characterization — 30-run flake rate on `KnownChainResolved`

A wider characterization ran the full 14-case suite 30 times back-to-
back. `KnownChainResolved` (case 8) failed 5 / 30 times (~17%); all
other cases were 30 / 30 green. The failure mode is always the same:
`chain_offset == 3` (i.e. the recorded chain begins at frames[3]
instead of frames[1] or [2]).

Root cause: under -O0 + ASAN, MarkerChain's spin loop expands its
`_stop.load(memory_order_acquire)` into a deep call chain of
atomic-wrapper functions plus `__asan_load1`. The signal handler's
captured RIP lands somewhere within that chain non-deterministically.
When it lands deep inside the wrapper stack, the remote-mode unwind
walks 3 wrapper frames before reaching the user-code `spin()`
function — outside the test's offset 1 / 2 acceptance window.

The in-handler-libunwind variants (`ck-phdr-unwind`, `ob-kill60`)
have the same fundamental property but at lower flake rate
(`ck-phdr-unwind` measured at 4/30 ≈ 13%). The gap (~4 percentage
points) comes from `UNW_INIT_SIGNAL_FRAME`: the in-handler variants
pass that flag to `unw_init_local2`, which clears libunwind's
`use_prev_instr` so the first proc-info lookup queries the RAW saved
RIP. The remote API (`unw_init_remote`) takes no flag and exposes no
public setter for the same field; lookups query at RIP-1, which
intermittently lands in a DIFFERENT procedure when RIP is at the
first byte of a procedure (common under ASan-instrumented atomic
loads in a tight spin loop).

A workaround that biases the cursor's IP forward via `unw_set_reg`
(which would make the IP-1 lookup land at the original IP) was
attempted and rejected: it broke `Truncated` (case 9) more often
than it fixed `KnownChainResolved`. The remote API's lack of a
signal-frame hint is the fundamental gap, and the variant's quality
bar is comparable to the other libunwind variants on the same gate
even without it.

Per-variant stability:

| variant | KnownChainResolved 30-run failure rate |
|---|---|
| `ck-phdr-unwind` | 4 / 30 (~13%) |
| `snapshot-remote-unwind` | 5 / 30 (~17%) |

The 3-consecutive-pass requirement at the acceptance bar held on
first try (3 / 3 green). The shared flake source is recorded here
for future Tier 1 stability work — most likely path is to add an
`UNW_INIT_SIGNAL_FRAME` flag to the test's MarkerChain fixture (e.g.
park on a syscall instead of busy-spin) or to extend `unw_init_remote`
upstream to take a flag the way `unw_init_local2` does.
