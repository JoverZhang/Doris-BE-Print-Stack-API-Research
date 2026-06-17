# PR 22549 minimal jemalloc/glibc dlerror reproducer

This is a standalone version of the
[`pr22549-jemalloc-dl-iterate-phdr`](../pr22549-jemalloc-dl-iterate-phdr/README.md)
startup reproducer. It does not build or start Doris.

Run from the project root:

```bash
./reproduce/pr22549-jemalloc-minimal/run.sh
```

Build only:

```bash
./reproduce/pr22549-jemalloc-minimal/build.sh
```

Defaults:

- `JOBS=$(nproc)`
- `REPRO_TIMEOUT=8`

The matrix uses these research sources:

```text
.mira/research-sources/jemalloc-5.3.0
.mira/research-sources/glibc-dlerror-deadlock-b2964eb
.mira/research-sources/glibc-dlerror-base-free-fada901
```

The two glibc source directories are named by matrix role:

- `glibc-dlerror-deadlock-b2964eb`: parent commit
  `b2964eb1d9a6b8ab1250e8a881cf406182da5875`; expected to deadlock with
  jemalloc profiling enabled.
- `glibc-dlerror-base-free-fada901`: commit
  `fada9018199c21c469ff0e731ef75c6020074ac9`; expected to complete because
  `dlerror` frees through the base namespace.

`build.sh` clones or updates those checkouts, builds jemalloc 5.3.0, builds the
two glibc installs under `.tmp/glibc-install/`, then links one reproducer binary
per glibc loader/libc.

The binary keeps only the pieces needed for the old PR 22549 hang:

- Doris-style malloc aliases from `jemalloc_hook.cpp`, so libc/libdl calls to
  `calloc` resolve to `jecalloc`.
- The old `dl_iterate_phdr` override path, where an empty PHDR cache calls
  `dlsym(RTLD_NEXT, "dl_iterate_phdr")`.
- A local `_Unwind_Backtrace` shim that makes jemalloc profiling initialization
  enter the local `dl_iterate_phdr` override. This avoids depending on the host
  libgcc implementation, which may use newer glibc paths such as
  `_dl_find_object`.

The runner executes four cases:

| Case | glibc | Profiling | Expected |
|---|---|---|---|
| `prev-prof-on` | `b2964eb` | on | deadlock |
| `prev-prof-off` | `b2964eb` | off | completed |
| `fixed-prof-on` | `fada901` | on | completed |
| `fixed-prof-off` | `fada901` | off | completed |

The profiling-off controls must complete without entering the local
`_Unwind_Backtrace` shim.

Expected result:

```text
PASS: glibc dlerror/jemalloc startup matrix matched expectations
```

Artifacts are written under:

```text
reproduce/pr22549-jemalloc-minimal/.tmp/latest/
```

`just phase2-reset` removes the `.tmp` directory.
