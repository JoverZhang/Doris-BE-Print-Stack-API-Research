# Phase 2 Evidence

Base Doris commit: `c24d454f15cee2d937ef4749270a3ecb449eafe6`.

Build image: `docker.io/apache/doris:build-env-ldb-toolchain-latest`; see `shared/docker-image.txt`.

## Shared Common API

Patch series:

- `patches/common/0001-feature-be-Add-native-stack-debug-API-stub.patch`

Key evidence:

- `shared/common-api-ninja-doris_be.txt`: successful `doris_be` target verification inside the Doris build image.
- `shared/common-api-build.failed-output-copy.txt`: `build.sh --be` reached `doris_be` link/install but failed later at `cp -p` during root `output/` packaging on this bind mount.
- `shared/be-startup-key.txt`: BE started from `be/output` in Docker with HTTP port 8040 mapped to host 18040.
- `shared/api-smoke/*.json`: API smoke results for `ok`, `missing_tid`, `timeout`, `busy`, and `bad_request`.

Runtime smoke used `be/output/conf/be.conf` with `enable_java_support = false`, because the common build explicitly disabled BE Java extensions and CDC client to avoid Maven dependency builds.

## Variant Results

Patch replay from base plus common passed for all four variants; see
`patch-check.txt`.

Current decision:

- Carry `fp-walk` forward as the next design to harden.
- Do not mark it production-approved yet; FE auth, query workload, allocation
  pressure, and churn rows remain open.

Variant summaries:

- `fp-walk`: lead candidate. Useful multi-frame stacks, no libunwind in signal
  handler, 50 repeated all-thread dumps passed.
- `ck-phdr-unwind`: rejected for production safety. Good frame coverage, but
  libunwind runs in the signal handler.
- `ob-kill60`: rejected for production safety and timeout tail. It also uses
  libunwind in the handler.
- `snapshot-remote-unwind`: rejected for current build usefulness. Handler is
  safest, but remote libunwind is stubbed and fallback stack walking only
  returned interrupted PCs.

Final comparison and decision files:

- `reviews/final-comparison.md`
- `evidence/phase2/decision.md`
