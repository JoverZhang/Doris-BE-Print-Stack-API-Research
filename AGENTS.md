# AGENTS.md

## Project Context

Read [README.md](README.md) first. It describes the current project state.

Do not read Phase 1 materials during Phase 2 work unless the user asks.

## Phase 2 Workflow

Keep `patches/` as the source of truth.
Use `phase2/*` as reproducible worktrees with build caches.

Do this:

- Run `just phase2-apply <target>` before building a target.
- Run `just phase2-diff <target>` to inspect temporary worktree changes.
- Run `just phase2-export <target>` only when you intentionally move committed
  worktree changes back into `patches/`.

Do not do this:

- Do not run `git clean -xfd` in `phase2/*` unless the user asks.
- Do not commit full all-thread JSON, full build logs, BE logs,
  `/proc/<pid>/maps`, binaries, or dumps.
- Do not rebuild thirdparty dependencies unless the user asks.

Use this build image:

- `docker.io/apache/doris:build-env-ldb-toolchain-latest`

## Reference Source Trees

Use these source trees when implementing related variants:

- ClickHouse: `repos/source/ClickHouse-v26.3.10.62-lts`
- OceanBase: `repos/source/oceanbase-v4.5.0_CE`

Rules:

- For `ck-phdr-unwind`, check the ClickHouse source before implementation.
- For `ob-kill60`, check the OceanBase source before implementation.
- Record the source files or symbols you used in the variant notes.

## Phase 2 Targets

Common API:

- `common`
- `common-api`

Variants:

- `fp-walk`
- `ck-phdr-unwind`
- `ob-kill60`
- `snapshot-remote-unwind`

## Common Commands

Use patch-first phase2 worktrees:

- `just phase2-status`
- `just phase2-apply <target>`
- `just phase2-diff <target>`
- `just phase2-export <target>`

Other commands:

- `just validate`

## Project Guidelines

- Follow [docs/writing-guidelines.md](docs/writing-guidelines.md) when writing
  or editing docs.
- Follow [docs/patch-guidelines.md](docs/patch-guidelines.md) when creating,
  editing, or exporting patch files.
