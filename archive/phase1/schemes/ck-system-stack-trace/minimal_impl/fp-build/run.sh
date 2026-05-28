#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$DIR" rev-parse --show-toplevel)"
CMAKE_PRESET="${CMAKE_PRESET:-debug}"
CMAKE_BUILD_PRESET="${CMAKE_BUILD_PRESET:-$CMAKE_PRESET}"
cd "$DIR"

(cd "$REPO_ROOT" && cmake --preset "$CMAKE_PRESET" >/dev/null)
(cd "$REPO_ROOT" && cmake --build --preset "$CMAKE_BUILD_PRESET" \
  --target ck_fp_vs_unwind_fp ck_fp_vs_unwind_no_fp >/dev/null
)

{
  echo "case=fp_enabled"
  ./build/fp_vs_unwind.fp
  echo
  echo "case=fp_omitted"
  ./build/fp_vs_unwind.no_fp
} > fp_vs_unwind.out

cat fp_vs_unwind.out
