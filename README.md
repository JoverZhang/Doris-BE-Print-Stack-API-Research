# Doris BE Print Stack API Research

[Doris#62497](https://github.com/apache/doris/issues/62497)

This repository studies ways to dump live native stacks from `doris_be`.

## Current State

Phase 1 is archived in [`archive/phase1/`](archive/phase1/README.md).

Phase 2 compares four stack collection designs inside Doris:

- ClickHouse-style PHDR-cache unwind in a signal handler.
- OceanBase-style two-phase `kill -60` collection.
- Snapshot plus remote unwind from copied stack bytes.
- Frame-pointer walking with Doris Release build flags.

The current Phase 2 decision is exploratory. `fp-walk` is the lead candidate,
but the full production matrix is not complete.

## Key Files

- [`AGENTS.md`](AGENTS.md): project instructions
- [`docs/phase2-plan.md`](docs/phase2-plan.md): original Phase 2 plan
- [`docs/writing-guidelines.md`](docs/writing-guidelines.md): project writing style
- [`docs/patch-guidelines.md`](docs/patch-guidelines.md): patch layout rules
- [`evidence/phase2/evaluation-protocol.md`](evidence/phase2/evaluation-protocol.md): next-run gates
- [`evidence/phase2/decision.md`](evidence/phase2/decision.md): attempt-1 decision
