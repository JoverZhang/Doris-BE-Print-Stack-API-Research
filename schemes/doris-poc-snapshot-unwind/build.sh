#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$BASE_DIR" rev-parse --show-toplevel)"
cd "$REPO_ROOT"
cmake --preset debug >/dev/null
cmake --build --preset debug --target doris_poc_snapshot_unwind
