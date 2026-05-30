#!/usr/bin/env bash
# Reason: the everyday "did this variant pass" command. The branch holds the
# applied state, so testing means switching and running the suite in the
# build container.
# Spec: docs/phase2-acceptance.md.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

variant="${1:?usage: test.sh <variant>}"

# 1. Refuse on dirty worktree; a switch would corrupt state.
assert_clean_worktree "$WORKTREE"

# 2. Switch to the variant branch.
git -C "$WORKTREE" switch "phase2/$variant"

# 3. Build and run the suite. run-be-ut.sh lives at the worktree root.
cd "$WORKTREE"
./run-be-ut.sh --run --filter="NativeStackActionTest.*" -j "$(nproc)"
