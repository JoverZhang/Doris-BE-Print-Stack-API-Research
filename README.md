# Doris BE Print Stack API Research

[Doris#62497](https://github.com/apache/doris/issues/62497)

This repository studies ways to dump live native stacks from `doris_be`.

Phase 1 is archived in [`archive/phase1/`](archive/phase1/README.md).
It contains the ClickHouse, OceanBase, eBPF, minidump, and standalone Doris POC evidence.

Phase 2 will test four stack collection designs inside Doris:

- ClickHouse-style PHDR-cache unwind in a signal handler.
- OceanBase-style two-phase `kill -60` collection.
- Snapshot plus remote unwind from copied stack bytes.
- Frame-pointer walking with Doris Release build flags.

Use `just phase1 --list` to list archived Phase 1 commands.
Use `just validate` to check repositories and archived lightweight builds.
