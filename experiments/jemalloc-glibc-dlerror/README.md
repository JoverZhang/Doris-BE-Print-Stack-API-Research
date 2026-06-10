# jemalloc/glibc `dlerror` Deadlock Experiment

This experiment isolates one allocator-loader boundary. It is independent from
Doris and does not read Doris source, patches, or Phase 2 test machinery.

## Claim

On glibc before 2.34, a successful `dlsym` path can allocate while producing
`dlerror` state. If jemalloc profiling is still bootstrapping, that allocation
can re-enter jemalloc initialization.

The target deadlock shape is:

```text
malloc_init_hard
prof_boot / prof_boot2 / prof_unwind_init
_Unwind_Backtrace
dl_iterate_phdr
dlsym
_dlerror_run
calloc or malloc
malloc_init_hard
```

The exact frame spelling can vary. The proof is the recursive allocator shape.

## Matrix

| Case | Image | jemalloc backend | Profiling | Expected |
|---|---|---|---|---|
| A | `ubuntu:20.04` | libgcc `_Unwind_Backtrace` | on | deadlock |
| B | `ubuntu:20.04` | libgcc `_Unwind_Backtrace` | off | completed |
| C | `ubuntu:20.04` | LLVM libunwind `unw_backtrace()` | on | completed |
| D | `ubuntu:24.04` | libgcc `_Unwind_Backtrace` | on | completed |

Case A proves the old glibc path can recurse into jemalloc. Case B proves
profiling is the trigger. Case C proves the LLVM libunwind backend avoids the
libgcc path. Case D proves the newer glibc path avoids this case.

## Files
- `Containerfile`: Ubuntu 20.04 or 24.04 image.
- `CMakeLists.txt`: build graph for jemalloc, LLVM libunwind, and repro bits.
- `deps/jemalloc`: jemalloc 5.3.0 source, pinned as a git submodule.
- `deps/llvm-project`: LLVM 17.0.6 source, pinned as a git submodule.
- `src/repro.c`: only `malloc(16)` and `free`.
- `src/phdr_wrap.c`: `dl_iterate_phdr` interposer.
- `justfile`: user entry point for build and run commands.
- `scripts/`: container and case-runner helpers.
- `results/`: small summaries; `results/raw/`: ignored raw logs.

## Run
From this directory:

```bash
just matrix
```

Run one row:

```bash
just case-A
just case-B
just case-C
just case-D
```

Build one jemalloc backend:

```bash
just build-jemalloc libgcc
just build-jemalloc llvm-libunwind
```

`justfile` is the user-facing flow. Read `case-A`, `case-B`, `case-C`, and
`case-D` top-down to see the container version, build steps, and run step for
each row. The scripts directory contains container helpers and the case runner.

The runner uses `podman` when present, otherwise `docker`. It passes ptrace
options so the timeout case can attach `gdb`.

## Build
Every backend builds jemalloc 5.3.0 from source with profiling enabled. The
system jemalloc package is not used.

CMake owns the build graph. `just build-jemalloc libgcc` builds and verifies
the libgcc-backed jemalloc. `just build-jemalloc llvm-libunwind` builds and
verifies the LLVM-libunwind-backed jemalloc. The `case-*` recipes build the
demo and wrapper explicitly after the allocator backend is ready.

Downloaded tarballs are not used. The source lives in git submodules:

```text
deps/jemalloc
deps/llvm-project
```

The gitlink commits pin the exact source revisions; the visible tags are
`5.3.0` and `llvmorg-17.0.6`.

The `libgcc` backend disables libunwind and gcc intrinsic fallback. That leaves
jemalloc's libgcc `_Unwind_Backtrace` backend enabled.

The `llvm-libunwind` path builds LLVM libunwind from source. It configures
jemalloc with libunwind enabled and libgcc disabled. Ubuntu `libunwind-dev` is
not used.

## Results

Each case writes:

```text
results/<case>.md
```

Timeout cases also write:

```text
results/raw/<case>/gdb-bt.txt
```

The raw directory is ignored. The small summaries can be kept.

## Reading Case A

Case A passes only when it times out and the `gdb` stack shows allocator
recursion through the unwind and loader path.

The script checks for:

- `malloc_init_hard`
- `_Unwind_Backtrace`
- `dl_iterate_phdr`
- `dlsym` or `_dlerror_run`

If Case A times out without this shape, the proof failed.

## Reading Controls

Case B must complete; if it hangs, profiling is not the only trigger.
Case C must complete; if it hangs, the LLVM libunwind control failed.
Case D must complete; if it hangs, the glibc-version control failed.

## Source References

- ClickHouse jemalloc rationale:
  https://raw.githubusercontent.com/ClickHouse/ClickHouse/f74c9de34f7b0a956d18330b00544a977ceb0347/contrib/jemalloc-cmake/CMakeLists.txt
- glibc commit mirror:
  https://github.com/bminor/glibc/commit/fada9018199c21c469ff0e731ef75c6020074ac9.patch
- glibc 2.33 `dlerror.c`:
  https://raw.githubusercontent.com/bminor/glibc/glibc-2.33/dlfcn/dlerror.c
- glibc 2.34 `dlerror.c`:
  https://raw.githubusercontent.com/bminor/glibc/glibc-2.34/dlfcn/dlerror.c
