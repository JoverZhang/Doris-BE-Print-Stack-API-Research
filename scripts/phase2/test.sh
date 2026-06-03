#!/usr/bin/env bash
# Reason: the everyday "did this variant pass" command. The branch holds the
# applied state, so testing means switching and running the suite in the
# build container.
# Spec: docs/phase2-acceptance.md.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

variant="${1:?usage: test.sh <variant>}"

# 1. Refuse on a dirty tree; a switch would corrupt state.
assert_clean_worktree "$DORIS_REPO"

# 2. Switch to the variant branch.
git -C "$DORIS_REPO" switch "phase2/$variant"

# 3. Build and run the suite. run-be-ut.sh lives at the doris-master root.
# BUILD_TYPE_UT picks the cmake build type and the parallel build dir
# (be/ut_build_${BUILD_TYPE_UT}); empty falls back to run-be-ut.sh's
# default ASAN. Supported: ASAN, RELEASE, TSAN, DEBUG, UBSAN, LSAN.
# The filter catches both the common `NativeStackActionTest` suite and per-
# variant suites named `<Variant>NativeStackActionTest` (e.g. `FpWalk…`),
# whose fixtures cannot share a class with common's at file scope.
build_type="${BUILD_TYPE_UT:-ASAN}"
args=(--run --filter="*NativeStackActionTest.*")
if [[ -n "${PHASE2_UT_JOBS:-}" ]]; then
    args+=(-j "${PHASE2_UT_JOBS}")
    jobs_label="${PHASE2_UT_JOBS}"
else
    jobs_label="doris-default"
fi

echo "phase2-test: variant=${variant} build_type=${build_type} jobs=${jobs_label}"
cd "$DORIS_REPO"
./run-be-ut.sh "${args[@]}"
