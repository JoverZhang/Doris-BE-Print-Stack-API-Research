# AGENTS.md

## Project Context

Read [README.md](README.md) first. It describes the current project state.

Do not read Phase 1 materials during Phase 2 work unless the user asks.

## Spec and Ownership

The Phase 2 spec is split by owner:

- [docs/phase2-charter.md](docs/phase2-charter.md): goal and constraints.
  Human-owned.
- [docs/phase2-acceptance.md](docs/phase2-acceptance.md): pass/fail gates.
  Human-owned.
- [docs/phase2-design.md](docs/phase2-design.md): API and variant mechanics.
  Agent-owned. Keep it in sync with the patches.

Do not edit the human-owned files. If a human-owned file seems wrong, stop and
report instead of changing it.

The current goal is to prove `fp-walk` first, as the baseline. See the charter.

Acceptance is by command, not by document. A variant is accepted only when its
tests pass under the acceptance doc.

## Phase 2 Workflow

Keep `patches/` as the source of truth.
Use `phase2/*` as reproducible worktrees with build caches.

Do this:

- Run `just phase2-apply <target>` before building a target.
- Run `just phase2-clean-apply <target>` only when the user explicitly asks
  for a clean re-apply. It deletes untracked and ignored files under
  `phase2/<target>`, including build caches.
- Run `just phase2-status [target]` to see what is applied.
- Run `just phase2-diff <target>` to inspect temporary worktree changes.
- Run `just phase2-export <target>` only when you intentionally move committed
  worktree changes back into `patches/`.
- Run `just phase2-test <variant>` to apply, build, and run the
  NativeStackActionTest suite in the build image.

Do not do this:

- Do not run `git clean -xfd` in `phase2/*` unless the user asks.
- Do not commit full all-thread JSON, full build logs, BE logs,
  `/proc/<pid>/maps`, binaries, or dumps.
- Do not rebuild thirdparty dependencies unless the user asks.

Use this build image:

- `docker.io/apache/doris:build-env-ldb-toolchain-latest`

## Reference Source Trees

Source-alias paths (`<ck>`, `<ob>`) live in
[docs/coding-guidelines.md](docs/coding-guidelines.md). Per-variant rules:

- For `ck-phdr-unwind`, check the ClickHouse source before implementation.
- For `ob-kill60`, check the OceanBase source before implementation.
- Record the source files or symbols you used in the variant notes.

## Project Guidelines

- Follow [docs/writing-guidelines.md](docs/writing-guidelines.md) when writing
  or editing docs.
- Follow [docs/coding-guidelines.md](docs/coding-guidelines.md) when writing
  or commenting code in patches.
- Follow [docs/patch-guidelines.md](docs/patch-guidelines.md) when creating,
  editing, or exporting patch files.
