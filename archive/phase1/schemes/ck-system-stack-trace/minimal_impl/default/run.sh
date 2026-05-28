#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$DIR" rev-parse --show-toplevel)"
CMAKE_PRESET="${CMAKE_PRESET:-debug}"
CMAKE_BUILD_PRESET="${CMAKE_BUILD_PRESET:-$CMAKE_PRESET}"
cd "$DIR"

(cd "$REPO_ROOT" && cmake --preset "$CMAKE_PRESET" >/dev/null)
(cd "$REPO_ROOT" && cmake --build --preset "$CMAKE_BUILD_PRESET" --target ck_directed_signal_unwind >/dev/null)

./build/directed_signal_unwind > directed_signal_unwind.out
cat directed_signal_unwind.out
