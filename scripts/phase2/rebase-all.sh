#!/usr/bin/env bash
# Reason: when phase2/common gains commits, every variant needs to rebase on
# top. Verify gates each rebase so a dropped hunk surfaces here, not at the
# next test run.
# Local: called by `just phase2-rebase-all`.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# 1. Refuse on dirty worktree.
assert_clean_worktree "$WORKTREE"

# 2. Remember the starting branch so we can return to it.
starting_branch=$(git -C "$WORKTREE" branch --show-current)

# 3. Rebase each variant on phase2/common; abort the loop on conflict.
for v in $VARIANTS; do
    git -C "$WORKTREE" switch "phase2/$v"
    if ! git -C "$WORKTREE" rebase phase2/common; then
        git -C "$WORKTREE" rebase --abort
        echo "error: rebase of phase2/$v failed; aborted" >&2
        exit 1
    fi
done

# 4. Return to the starting branch.
git -C "$WORKTREE" switch "$starting_branch"
echo "rebase-all complete; run phase2-verify per variant"
