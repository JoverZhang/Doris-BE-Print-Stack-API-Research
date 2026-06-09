#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$ROOT/scripts/common.sh"

"$ROOT/scripts/build_libunwind.sh"
"$ROOT/scripts/build_example.sh"

echo "capturing frames: $FRAMES"
"$BIN" > "$FRAMES"

"$ROOT/scripts/verify_example.sh"
