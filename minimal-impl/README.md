# minimal-impl: stack-walk isolation lab

A standalone reproduction of the Phase 2 fp-walk vs libunwind question, isolated
from Doris. Four build variants × two walker implementations = an 8-cell matrix
that answers "which combinations actually work, and why."

## What's here

```
src/
  stack_walker.h          Interface
  stack_walker_fp.cpp     RBP-chain walker
  stack_walker_unwind.cpp libunwind wrapper
  signal_harness.{h,cpp}  SIGPROF handler entry
  workload.{h,cpp}        Five-frame deterministic call chain
  main.cpp                CLI + dladdr-based verification

tools/
  elf_inspect.cpp         libdw-based CFI classifier (sections + layout)

scripts/
  build_all.sh            Builds all four variants
  run_matrix.sh           Runs every variant × walker, prints table
  inspect.sh              Pretty-prints ELF + CFI for one binary
```

## Build variants

| Variant | Flags | What it tests |
|---|---|---|
| `asan` | `-O1 -g -fno-omit-frame-pointer -fsanitize=address` | sanitizer baseline |
| `tsan` | `-O1 -g -fno-omit-frame-pointer -fsanitize=thread` | TSAN signal-handler conflict |
| `release_fp` | `-O3 -DNDEBUG -g -fno-omit-frame-pointer` | Doris BE production |
| `release_nofp` | `-O3 -DNDEBUG -g -fomit-frame-pointer` | **control: no frame ptr** |

Each variant builds to `build/<variant>/`; running one never touches another.

## Required dependencies

- libunwind (`/usr/lib/libunwind.so`)
- elfutils libdw + libelf (`/usr/lib/libdw.so`, `/usr/lib/libelf.so`)
- CMake 3.16+, Ninja, gcc/clang with C++17

All three libs ship with every major distro. CMake fails the configure step
if any is missing.

## Quick start

```bash
just build-all       # builds all four variants
just run-matrix      # runs the 8-cell matrix, prints a markdown table
just inspect release_fp     # ELF + CFI summary for the release_fp binary
```

## Expected matrix

| Walker × Variant | asan | tsan | release_fp | release_nofp |
|---|---|---|---|---|
| `fp` | pass | mostly pass | pass | **FAIL** (no frame ptr) |
| `unwind` | pass | **FAIL** (TSAN+signal) | pass | pass |

The headline finding this lab adds beyond Phase 2: `release_nofp + fp` fails
for code-generation reasons (no RBP chain to walk), independent of any
sanitizer instrumentation. This is the strongest argument for libunwind
in any build where `-fomit-frame-pointer` might be in effect.

## elf_inspect

Reads `.eh_frame` CFI via libdw and reports, per function:
- Canonical Frame Address rule (`rbp + N` vs `rsp + N`)
- Saved RIP/RBP offsets
- First 8 prologue bytes (with the common patterns annotated)

Run `just inspect release_fp` and `just inspect release_nofp` to see the
same function classified two different ways from two different binaries —
no hand-written diagrams.
