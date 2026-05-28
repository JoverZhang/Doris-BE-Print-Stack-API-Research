#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
CMAKE_PRESET="${CMAKE_PRESET:-debug}"
CMAKE_BUILD_PRESET="${CMAKE_BUILD_PRESET:-$CMAKE_PRESET}"

(cd "$REPO_ROOT" && cmake --preset "$CMAKE_PRESET" >/dev/null)
(cd "$REPO_ROOT" && cmake --build --preset "$CMAKE_BUILD_PRESET" \
  --target ebpf_profile_target_fp ebpf_profile_target_nofp >/dev/null
)
