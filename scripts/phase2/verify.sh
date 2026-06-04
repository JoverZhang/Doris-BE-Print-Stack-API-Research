#!/usr/bin/env bash
# Reason: tree-id equality is the strongest acceptance for round-trip patch
# fidelity. It catches stale patches/ before they reach review.
# Local: called by `just phase2-verify <variant>`.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

variant="${1:?usage: verify.sh <variant>}"
verify_dir="$PROJECT_ROOT/.tmp/verify-$variant"

# 1. VTREE = tree of the working branch.
vtree=$(git -C "$DORIS_REPO" rev-parse "phase2/$variant^{tree}")

# 2. Cleanup any stale verify worktree before creating a fresh one.
cleanup_worktree "$verify_dir"

# 3. Create an ephemeral worktree at DORIS_BASE.
ensure_git_identity "$DORIS_REPO"
git -C "$DORIS_REPO" worktree add --detach "$verify_dir" "$DORIS_BASE"

# 4. Apply common first; then the variant unless variant == common.
git -C "$verify_dir" am "$PROJECT_ROOT/patches/common/"*.patch
if [[ "$variant" != "common" ]]; then
    git -C "$verify_dir" am "$PROJECT_ROOT/patches/$variant/"*.patch
fi
if [[ "$variant" == "ck-phdr-unwind" ]]; then
    DORIS_REPO="$verify_dir" "$PROJECT_ROOT/scripts/phase2/check-ck-phdr-unwind.sh" "$verify_dir"
fi

# 5. STREE = tree of the re-applied state.
stree=$(git -C "$verify_dir" rev-parse "HEAD^{tree}")

# 6. Remove the ephemeral worktree.
git -C "$DORIS_REPO" worktree remove --force "$verify_dir"

# 7. Compare.
if [[ "$vtree" != "$stree" ]]; then
    echo "FAIL: phase2/$variant ($vtree) != re-applied ($stree)" >&2
    exit 1
fi
echo "OK: phase2/$variant round-trips with patches/"
