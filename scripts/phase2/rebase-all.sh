#!/usr/bin/env bash
# Reason: when phase2/common gains commits, every variant needs to rebase on
# top. Verify gates each rebase so a dropped hunk surfaces here, not at the
# next test run.
# Local: called by `just phase2-rebase-all`.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# 1. Refuse on a dirty tree.
assert_clean_worktree "$DORIS_REPO"

# 2. Remember the starting branch so we can return to it.
starting_branch=$(git -C "$DORIS_REPO" branch --show-current)

# 3. Rebase each variant on phase2/common; abort the loop on conflict.
for v in $VARIANTS; do
    git -C "$DORIS_REPO" switch "phase2/$v"
    if ! git -C "$DORIS_REPO" rebase phase2/common; then
        git -C "$DORIS_REPO" rebase --abort
        echo "error: rebase of phase2/$v failed; aborted" >&2
        exit 1
    fi
done

# 4. Return to the starting branch.
git -C "$DORIS_REPO" switch "$starting_branch"
echo "rebase-all complete; run phase2-verify per variant"
