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

`patches/` is the source of truth for review. The `repos/source/doris-master`
submodule holds the applied state on branches `phase2/base`, `phase2/common`,
and `phase2/<variant>`. All git and build operations run inside the build
container; never invoke them on the host.

Do this:

- Run `just phase2-bootstrap` on first setup to create the phase2/* branch
  stack in `repos/source/doris-master` from `patches/`. Cold cost: a few
  minutes for submodule init.
- Run `just phase2-test <variant>` to switch, build, and run the
  NativeStackActionTest suite. `<variant>` is `common`, `fp-walk`, etc.
- Run `just phase2-test-release <variant>` or `just phase2-test-tsan
  <variant>` to run the same suite under RELEASE (`-O3 -DNDEBUG`) or
  TSAN (`-O1 -fsanitize=thread`). Each mode uses its own sibling build
  dir (`be/ut_build_{RELEASE,TSAN}`). `just phase2-test-all <variant>`
  runs all three modes in sequence.
- Run `just phase2-verify <variant>` to confirm `patches/<variant>`
  round-trips against the branch.
- Run `just phase2-export [variant]` after committing on a branch to
  regenerate `patches/`. Filenames derive from commit subjects.
- Run `just phase2-status` to see current branch and per-scope commit/patch
  counts.
- Run `just phase2-shell` to drop into an interactive container for diagnostics.
- Run `just phase2-rebase-all` after committing to `phase2/common` to rebase
  every variant on the new common.
- Run `just phase2-teardown` to remove the worktree and every `phase2/*`
  branch (rebuild via `phase2-bootstrap`).

Do not do this:

- Do not run `git`, `cmake`, `ninja`, `be/build.sh`, or `run-be-ut.sh`
  directly. Always go through `just phase2-*`.
- Do not commit full all-thread JSON, full build logs, BE logs,
  `/proc/<pid>/maps`, binaries, or dumps.
- Do not rebuild thirdparty dependencies unless the user asks.

Build image: `docker.io/apache/doris:build-env-ldb-toolchain-latest`.

## Reference Source Trees

Source-alias paths (`<ck>`, `<ob>`) live in
[docs/coding-guidelines.md](docs/coding-guidelines.md). Per-variant rules:

- For `ck-phdr-unwind`, check the ClickHouse source before implementation.
- For `ob-kill60`, check the OceanBase source before implementation.

## Project Guidelines

- Follow [docs/writing-guidelines.md](docs/writing-guidelines.md) when writing
  or editing docs.
- Follow [docs/coding-guidelines.md](docs/coding-guidelines.md) when writing
  or commenting code in patches.
