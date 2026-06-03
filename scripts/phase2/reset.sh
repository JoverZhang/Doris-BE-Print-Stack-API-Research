#!/usr/bin/env bash
# Reason: restore the Doris phase2 worktree to a clean base state without
# deleting local build outputs or compiler cache. This clears UT-generated
# source-tree artifacts, detaches at DORIS_BASE, and removes phase2/* branches
# so phase2-bootstrap can recreate the stack.
# Local: harness reset, called by `just phase2-reset`.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

rebase_merge="$(git -C "$DORIS_REPO" rev-parse --git-path rebase-merge)"
rebase_apply="$(git -C "$DORIS_REPO" rev-parse --git-path rebase-apply)"
if [[ -d "$rebase_merge" || -d "$rebase_apply" ]]; then
    echo "error: $DORIS_REPO has an in-progress git am/rebase; abort or finish it before phase2-reset" >&2
    exit 1
fi

# 1. Clear tracked changes and untracked test artifacts. Do not use -x: ignored
# build dirs stay. Keep the known UT build dirs explicit in case ignore rules
# drift in this checkout.
git -C "$DORIS_REPO" reset --hard
git -C "$DORIS_REPO" clean -fd \
    -e 'be/ut_build*/' \
    -e 'be/ut_build*'

# 2. Detach at the configured base commit, not at a branch name such as master.
git -C "$DORIS_REPO" switch --detach "$DORIS_BASE"

# 3. Delete every phase2/* branch in the submodule.
for ref in $(git -C "$DORIS_REPO" for-each-ref --format="%(refname:short)" refs/heads/phase2/); do
    git -C "$DORIS_REPO" branch -D "$ref"
done

echo "phase2 reset complete: Doris source tree is clean, phase2/* branches removed, build dirs preserved"
