# PHDR Cache Incompleteness Experiment Plan

## Goal

Classify what nongnu libunwind does when a CK/Doris-style
`dl_iterate_phdr` cache is incomplete or stale:

- fewer frames with a clean stop
- an early stop before the target frames
- a wrong frame
- a process crash

This is a standalone experiment. It does not modify Doris source and does not
use the Phase 2 BE build.

## Harness

1. Build nongnu libunwind from the existing local source at
   `../jemalloc-glibc-dlerror/deps/libunwind`.
2. Build a `driver` executable that defines a global `dl_iterate_phdr`
   override with the same shape as the CK/Doris PHDR cache:
   - before cache population, delegate to the real libc function
   - after cache population, call the supplied callback from a cached list
3. Build two shared plugins:
   - `libplugin_a.so`
   - `libplugin_b.so`
4. Each plugin has a fixed noinline call chain:
   `plugin_*_entry -> plugin_*_mid -> plugin_*_leaf -> capture_stack`.
5. `capture_stack` runs `unw_getcontext`, `unw_init_local`, and repeated
   `unw_step`, then emits frame rows.

Plugins are compiled with unwind tables and frame pointers omitted so the
walk depends on ELF unwind metadata rather than a simple frame-pointer chain.

## Matrix

| Case | Scenario | Cache state | Expected class |
|---|---|---|---|
| A | `complete` | cache built after `dlopen(plugin_a)` | full stack |
| B | `missing-plugin` | cache built before `dlopen(plugin_a)` | truncated or stopped, no crash |
| C | `stale-dlclose` | cache has `plugin_a`; then `plugin_a` is closed and `plugin_b` is loaded | full stack in this minimal loader layout |
| D | `poison-plugin` | cache has `plugin_a`, but its `dlpi_phdr` pointer is overwritten with an invalid address | crash |
| E | `missing-main` | cache built after `dlopen(plugin_a)` but the executable entry is omitted | error frame then stop |

## Classification

Each case writes raw rows and a small summary.

Frame quality:

- `full`: expected plugin frames and `main` are present
- `prefix-truncated`: the walk records a prefix but misses later expected
  frames
- `wrong-frame`: frames contain the wrong plugin or another non-prefix frame
- `error-frame`: frames contain an invalid IP or unresolved frame
- `no-frames`: no frame row is emitted
- `crashed`: the process dies before a normal stop classification

Termination:

- `normal`: process exits with status 0
- `signal(SIG*)`: process dies by signal
- `timeout`: runner kills a stuck process
- `failed(N)`: process exits non-zero without a signal

## Deliverables

- `README.md`: experiment summary and commands.
- `justfile`: user entry points.
- `scripts/`: container, build, and single-case runner.
- `src/`: minimal PHDR cache, driver, and plugins.
- `results/*.md`: committed small summaries.
- `results/raw/`: ignored detailed logs.

## Acceptance

Run:

```bash
just matrix
```

The matrix passes only if the complete baseline is full, the missing-cache
cases do not crash, and the stale/poison cases are classified consistently.
