#!/usr/bin/env bash
# Reason: branches drift ahead of patches/ as agents commit. Export
# regenerates patches/ so reviewers and verify see current files. Always
# re-emits common since variants depend on it.
# Local: called by `just phase2-export [variant]`.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

variant="${1:-}"

# 1. Refuse on dirty worktree.
assert_clean_worktree "$WORKTREE"

# 2. Regenerate patches/common from phase2/base..phase2/common.
rm -f "$PROJECT_ROOT/patches/common/"*.patch
git -C "$WORKTREE" format-patch \
    --output-directory "$PROJECT_ROOT/patches/common/" \
    phase2/base..phase2/common >/dev/null

# 3. Regenerate patches/<v> for each variant in scope.
if [[ -z "$variant" ]]; then
    targets="$VARIANTS"
else
    targets="$variant"
fi
for v in $targets; do
    if [[ "$v" == "common" ]]; then
        continue
    fi
    rm -f "$PROJECT_ROOT/patches/$v/"*.patch
    git -C "$WORKTREE" format-patch \
        --output-directory "$PROJECT_ROOT/patches/$v/" \
        "phase2/common..phase2/$v" >/dev/null
done

echo "export complete; run phase2-verify <variant> to confirm round-trip"
