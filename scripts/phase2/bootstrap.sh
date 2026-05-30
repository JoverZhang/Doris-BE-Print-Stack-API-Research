#!/usr/bin/env bash
# Reason: convert patches/ into the branch stack on first setup. Without it,
# the harness has no branches to operate on. Common is strict (the variant
# stack is meaningless without it); each variant is tolerated independently
# so one stale patch series does not block the rest.
# Local: one-shot harness setup, called by `just phase2-bootstrap`.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# 1. Refuse if the worktree or any phase2/* branch already exists.
if [[ -d "$WORKTREE" ]]; then
    echo "error: $WORKTREE already exists; run phase2-teardown first" >&2
    exit 1
fi
if git -C "$DORIS_REPO" show-ref --verify --quiet refs/heads/phase2/base; then
    echo "error: phase2/* branches already exist in $DORIS_REPO" >&2
    exit 1
fi

# 2. Make sure the submodule has a committer identity for git am.
ensure_git_identity "$DORIS_REPO"

# 3. Create the worktree on a new phase2/base branch at DORIS_BASE.
git -C "$DORIS_REPO" worktree add -b phase2/base "$WORKTREE" "$DORIS_BASE"

# 4. Initialize submodules in the worktree. Doris build needs contrib/faiss,
#    contrib/openblas, and others; a fresh worktree starts with them empty.
#    Recursive so nested submodules (e.g. apache-orc) check out too.
echo "initializing submodules (may take a few minutes on cold cache)..."
git -C "$WORKTREE" submodule update --init --recursive

# 5. Create phase2/common; apply patches/common/*.patch strictly.
git -C "$WORKTREE" switch -c phase2/common
git -C "$WORKTREE" am "$PROJECT_ROOT/patches/common/"*.patch

# 6. For each variant: branch from phase2/common; try to apply. On failure
#    abort cleanly so the next variant can still run.
clean=()
broken=()
for v in $VARIANTS; do
    git -C "$WORKTREE" switch phase2/common
    git -C "$WORKTREE" switch -c "phase2/$v"
    if git -C "$WORKTREE" am "$PROJECT_ROOT/patches/$v/"*.patch; then
        clean+=("$v")
    else
        git -C "$WORKTREE" am --abort 2>/dev/null || true
        git -C "$WORKTREE" switch phase2/common
        git -C "$WORKTREE" branch -D "phase2/$v"
        broken+=("$v")
    fi
done

# 7. Leave on phase2/common as the natural default.
git -C "$WORKTREE" switch phase2/common

echo
echo "bootstrap summary:"
echo "  clean:   common ${clean[*]}"
if [[ ${#broken[@]} -gt 0 ]]; then
    echo "  broken:  ${broken[*]}"
    echo
    echo "broken variants need patch regeneration. Investigate with:"
    echo "  cd $WORKTREE && git am --3way \"$PROJECT_ROOT/patches/<v>/\"*.patch"
else
    echo "  broken:  none"
fi
