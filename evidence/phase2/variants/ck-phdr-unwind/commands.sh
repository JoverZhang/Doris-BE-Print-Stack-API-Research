#!/usr/bin/env bash
# Reproduce the ck-phdr-unwind Tier 1 evaluation from this repo.
# Assumes:
#   - the build image docker.io/apache/doris:build-env-ldb-toolchain-latest
#     is already pulled (the harness's in-container helper runs it).
#   - .worktree/phase2 has been bootstrapped at least once via
#     `just phase2-bootstrap` (re-uses the existing branches; ck-phdr-unwind
#     joins phase2-bootstrap once added to scripts/phase2/_common.sh VARIANTS).
#   - .worktree/phase2 is clean.
set -euo pipefail

# 1. Switch to the variant and build/run NativeStackActionTest in the container.
just phase2-test ck-phdr-unwind

# 2. Verify the patch series round-trips against the worktree's tree.
just phase2-verify ck-phdr-unwind

# 3. (Optional) Regenerate patches from branch state after a commit.
# just phase2-export ck-phdr-unwind
