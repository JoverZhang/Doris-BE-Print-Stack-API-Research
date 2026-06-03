#!/usr/bin/env bash
# Reason: fast diagnostic entrypoint for any BE UT gtest filter on a phase2
# branch. This keeps ad-hoc repros inside the same container/branch workflow as
# the acceptance recipes.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

variant="${1:?usage: test-filter.sh <variant-or-base> <gtest-filter>}"
filter="${2:?usage: test-filter.sh <variant-or-base> <gtest-filter>}"

# 1. Refuse on a dirty tree; a switch would corrupt state.
assert_clean_worktree "$DORIS_REPO"

# 2. Switch to the requested phase2 branch. `base` is valid for upstream
# baseline checks because bootstrap creates phase2/base.
git -C "$DORIS_REPO" switch "phase2/$variant"

# 3. Build and run only the requested gtest filter. Build dirs are separated by
# BUILD_TYPE_UT via Doris's run-be-ut.sh.
build_type="${BUILD_TYPE_UT:-ASAN}"
args=(--run --filter="${filter}")
if [[ -n "${PHASE2_UT_JOBS:-}" ]]; then
    args+=(-j "${PHASE2_UT_JOBS}")
    jobs_label="${PHASE2_UT_JOBS}"
else
    jobs_label="doris-default"
fi

head="$(git -C "$DORIS_REPO" rev-parse --short=12 HEAD)"
echo "phase2-test-filter: branch=phase2/${variant} head=${head} build_type=${build_type} jobs=${jobs_label} filter=${filter}"
cd "$DORIS_REPO"
./run-be-ut.sh "${args[@]}"
