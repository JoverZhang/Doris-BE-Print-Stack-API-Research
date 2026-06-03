#!/usr/bin/env bash
# Reason: local full BE UT entrypoint that preserves build dirs by default.
# CI parity stays available via the explicit --clean flag.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

variant="${1:?usage: full-ut.sh <variant> [--clean]}"
clean="${2:-}"
if [[ -n "${clean}" && "${clean}" != "--clean" ]]; then
    echo "usage: full-ut.sh <variant> [--clean]" >&2
    exit 2
fi

# 1. Refuse on a dirty tree; a switch would corrupt state.
assert_clean_worktree "$DORIS_REPO"

# 2. Switch to the variant branch.
git -C "$DORIS_REPO" switch "phase2/$variant"

# 3. Build and run every BE UT. Without --clean, Doris reuses the
# be/ut_build_${BUILD_TYPE_UT} dir; with --clean, it matches CI behavior.
build_type="${BUILD_TYPE_UT:-ASAN}"
args=(--run)
if [[ -n "${PHASE2_UT_JOBS:-}" ]]; then
    args+=(-j "${PHASE2_UT_JOBS}")
    jobs_label="${PHASE2_UT_JOBS}"
else
    jobs_label="doris-default"
fi

if [[ "${clean}" == "--clean" ]]; then
    args+=(--clean)
fi

echo "phase2-full-ut: variant=${variant} build_type=${build_type} jobs=${jobs_label} clean=$([[ "${clean}" == "--clean" ]] && echo yes || echo no)"
cd "$DORIS_REPO"
./run-be-ut.sh "${args[@]}"
