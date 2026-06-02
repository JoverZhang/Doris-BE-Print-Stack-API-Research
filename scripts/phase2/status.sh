#!/usr/bin/env bash
# Reason: an agent needs a fast read of "where am I, are patches/ in sync"
# without paying for a full verify. Convenience, not authority.
# Local: called by `just phase2-status`.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

if ! git -C "$DORIS_REPO" show-ref --verify --quiet refs/heads/phase2/base; then
    echo "not bootstrapped; run phase2-bootstrap"
    exit 0
fi

# 1. Current branch.
echo "branch: $(git -C "$DORIS_REPO" branch --show-current)"
echo

# 2. Commit count per branch and patch-file count per scope.
printf "%-30s %8s %8s\n" "scope" "commits" "patches"
cc=$(git -C "$DORIS_REPO" rev-list --count phase2/base..phase2/common 2>/dev/null || echo "?")
pc=$(find "$PROJECT_ROOT/patches/common" -maxdepth 1 -name "*.patch" 2>/dev/null | wc -l)
printf "%-30s %8s %8s\n" "common" "$cc" "$pc"
for v in $VARIANTS; do
    cc=$(git -C "$DORIS_REPO" rev-list --count "phase2/common..phase2/$v" 2>/dev/null || echo "?")
    pc=$(find "$PROJECT_ROOT/patches/$v" -maxdepth 1 -name "*.patch" 2>/dev/null | wc -l)
    printf "%-30s %8s %8s\n" "$v" "$cc" "$pc"
done
