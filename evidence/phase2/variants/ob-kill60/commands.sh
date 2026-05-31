#!/usr/bin/env bash
# Reproduce the ob-kill60 Tier 1 evaluation from this repo.
# Assumes:
#   - the build image docker.io/apache/doris:build-env-ldb-toolchain-latest
#     is already pulled (the harness's in-container helper runs it).
#   - .worktree/phase2 has been bootstrapped at least once via
#     `just phase2-bootstrap` (re-uses the existing branches; ob-kill60
#     joins phase2-bootstrap because scripts/phase2/_common.sh VARIANTS
#     now includes it).
#   - .worktree/phase2 is clean.
set -euo pipefail

# 1. Switch to the variant and build/run NativeStackActionTest in the container.
just phase2-test ob-kill60

# 2. Verify the patch series round-trips against the worktree's tree.
just phase2-verify ob-kill60

# 3. (Optional) Regenerate patches from branch state after a commit.
# just phase2-export ob-kill60
