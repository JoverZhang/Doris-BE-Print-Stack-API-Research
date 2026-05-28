#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$BASE_DIR" rev-parse --show-toplevel)"
CMAKE_PRESET="${CMAKE_PRESET:-debug}"
CMAKE_BUILD_PRESET="${CMAKE_BUILD_PRESET:-$CMAKE_PRESET}"

(cd "$REPO_ROOT" && cmake --preset "$CMAKE_PRESET" >/dev/null)
(cd "$REPO_ROOT" && cmake --build --preset "$CMAKE_BUILD_PRESET" \
  --target ob_open_obstack_target ob_open_obstack_ptrace_remote_unwind >/dev/null
)
