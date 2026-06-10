# PHDR Cache Incompleteness Experiment

This experiment isolates the CK/Doris-style `dl_iterate_phdr` cache and asks
what happens when libunwind needs PHDR data that the cache does not contain.

It is independent from Doris. It reuses the local nongnu libunwind source from
`../jemalloc-glibc-dlerror/deps/libunwind`.

## Claim Under Test

An incomplete PHDR cache should usually make libunwind lose frames and stop.
A dangling or corrupt PHDR entry is a different risk: it can crash while the
unwinder reads stale ELF metadata.

## Matrix

| Case | Scenario | Expected |
|---|---|---|
| A | complete cache after `dlopen(plugin_a)` | full stack, normal exit |
| B | cache built before `dlopen(plugin_a)` | truncated stack, normal exit |
| C | cache has closed `plugin_a`, then walks through `plugin_b` | full stack in this minimal loader layout |
| D | plugin PHDR pointer poisoned to an invalid address | SIGSEGV |
| E | executable PHDR entry omitted | error frame, normal exit |

Case C is intentionally narrow: in this harness the loader consistently
reuses the plugin mapping closely enough that the stale entry still produces a
full walk. Case D is the deterministic dangling-PHDR probe.

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
just case-E
```

The runner uses `podman` when present, otherwise `docker`.

## Results

Each case writes:

```text
results/<case>.md
```

Detailed rows and stderr go under:

```text
results/raw/<case>/
```

The raw directory is ignored. Keep the small summaries.

## Observed Result

On the committed run:

| Case | Observed | Meaning |
|---|---|---|
| A | `full`, `normal` | Baseline cache walks through plugin frames and back to `main`. |
| B | `prefix-truncated`, `normal` | Missing plugin PHDR loses middle plugin frames without crashing. |
| C | `full`, `normal` | This minimal `dlclose`/`dlopen` layout does not expose dangling failure. |
| D | `crashed`, `signal(SIGSEGV)` | A corrupt plugin `dlpi_phdr` can crash the unwinder. |
| E | `error-frame`, `normal` | Missing executable PHDR can produce unresolved/invalid frames, then stop. |
