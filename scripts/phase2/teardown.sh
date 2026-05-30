#!/usr/bin/env bash
# Reason: clean removal so phase2-bootstrap can re-run. Removes the worktree
# directory and every phase2/* branch. Safe to call when partially set up.
# Local: harness teardown, called by `just phase2-teardown`.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# 1. Remove the worktree directory and prune the registry.
cleanup_worktree "$WORKTREE"

# 2. Delete every phase2/* branch in the submodule.
for ref in $(git -C "$DORIS_REPO" for-each-ref --format="%(refname:short)" refs/heads/phase2/); do
    git -C "$DORIS_REPO" branch -D "$ref"
done

echo "teardown complete"
