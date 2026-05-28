# Variant Subagent Brief Template

Use this template after the common harness and one calibration variant pass.

## Assignment

Implement and evaluate exactly one variant: `<variant>`.

Worktree: `<absolute Doris worktree path>`.

Project evidence directory:
`/home/mira/lab/projects/Doris-BE-Print-Stack-API-Research/evidence/phase2/variants/<variant>/`.

Patch output:
`/home/mira/lab/projects/Doris-BE-Print-Stack-API-Research/patches/<variant>/`.

## Fixed Inputs

- Base commit: `c24d454f15cee2d937ef4749270a3ecb449eafe6`.
- Build image: `docker.io/apache/doris:build-env-ldb-toolchain-latest`.
- Thirdparty dependencies are already downloaded and compiled. Do not rebuild
  thirdparty.
- Common API patch is fixed. Do not change the route, JSON contract, auth
  contract, busy behavior, timeout semantics, or response field names.
- Use `evidence/phase2/evaluation-protocol.md` as the acceptance contract.

## Allowed Writes

- Your Doris variant worktree.
- `patches/<variant>/`.
- `evidence/phase2/variants/<variant>/`.

Do not edit other variants, shared API files, root decision files, or reviews.
If a shared issue blocks you, stop and report the exact error plus the smallest
proposed shared fix.

## Known Environment Facts

- The requested Docker image is already local.
- `build.sh --be` may reach BE link/install and then fail during root `output/`
  packaging because of bind-mount permission preservation. Verify
  `cmake --build be/build_Release --target doris_be -j 8` separately.
- Installed libunwind may expose local-only `_ULx86_64_*` symbols; do not guess
  symbol prefixes from docs. Verify against installed headers and archives.
- In the previous run, remote libunwind address-space creation was stubbed in
  the linked thirdparty archive. Recheck before depending on it.

## Required Output

Tracked:

- `manifest.yaml`: commit SHA, patch path, image ID, build command, runtime
  command, variant-specific assumptions.
- `commands.sh`: exact commands to reproduce build, run, and tests.
- `verdict.md`: `pass`, `hold`, `policy-fail`, or `fail`, with gate-by-gate
  reasons.
- concise metrics CSV/MD only.
- one small one-TID JSON sample and short status samples.
- build facts and known-stack symbolization excerpt.

Ignored/raw:

- full all-thread JSON
- full build logs
- full BE logs
- `/proc/<pid>/maps`
- binaries and dumps

Put raw files under `evidence/phase2/raw/<run-id>/<variant>/` or
`artifacts/phase2/raw/<run-id>/<variant>/`.

## Stop Conditions

Stop and report `hold` instead of improvising when:

- the common API contract needs to change
- a shared build/environment issue appears
- a timeout tail appears and instrumentation is missing
- remote unwinder capability contradicts the variant design
- required matrix rows cannot run under the shared harness
