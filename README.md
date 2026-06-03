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

The current goal is to prove `fp-walk` first, as the baseline, gated by tests
that ship in the patches. The other three designs are compared only after the
baseline passes.

## Key Files

- [`AGENTS.md`](AGENTS.md): project instructions
- [`docs/phase2-charter.md`](docs/phase2-charter.md): goal and constraints (human-owned)
- [`docs/phase2-acceptance.md`](docs/phase2-acceptance.md): pass/fail gates (human-owned)
- [`docs/architecture.md`](docs/architecture.md): variant-agnostic contract and structure for the print_stack API (agent-owned)
- [`docs/phase2-design.md`](docs/phase2-design.md): variant mechanics (agent-owned)
- [`docs/phase2-test-plan.md`](docs/phase2-test-plan.md): acceptance checks as concrete tests (agent-owned)
- [`docs/writing-guidelines.md`](docs/writing-guidelines.md): project writing style
- [`docs/coding-guidelines.md`](docs/coding-guidelines.md): code and comment conventions
- [`evidence/phase2/subagent-brief-template.md`](evidence/phase2/subagent-brief-template.md): per-variant dispatch brief
