#!/usr/bin/env bash
# Reason: clean removal so phase2-bootstrap can re-run. Removes every phase2/*
# branch in the doris-master submodule. Safe to call when partially set up.
# Local: harness teardown, called by `just phase2-teardown`.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# 1. If a phase2/* branch is the current HEAD, detach off it first so we can
#    delete it. Switching to DORIS_BASE leaves the submodule in the same
#    state a fresh `submodule update` would.
current=$(git -C "$DORIS_REPO" branch --show-current 2>/dev/null || true)
if [[ "$current" == phase2/* ]]; then
    git -C "$DORIS_REPO" switch --detach "$DORIS_BASE"
fi

# 2. Delete every phase2/* branch in the submodule.
for ref in $(git -C "$DORIS_REPO" for-each-ref --format="%(refname:short)" refs/heads/phase2/); do
    git -C "$DORIS_REPO" branch -D "$ref"
done

echo "teardown complete"
