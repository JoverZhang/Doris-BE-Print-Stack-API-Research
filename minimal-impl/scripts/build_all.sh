#!/usr/bin/env bash
# Build all four variants. Each lands in build/<variant>/.
set -euo pipefail

cd "$(dirname "$0")/.."

VARIANTS=(asan tsan release_fp release_nofp)
for v in "${VARIANTS[@]}"; do
    echo "=== Building $v ==="
    cmake -B "build/$v" -DBUILD_VARIANT="$v" -G Ninja -S . >/dev/null
    cmake --build "build/$v"
done

echo
echo "All variants built:"
for v in "${VARIANTS[@]}"; do
    if [[ -x "build/$v/min_stack_collect" ]]; then
        echo "  build/$v/min_stack_collect  $(stat -c'%s' "build/$v/min_stack_collect") bytes"
    fi
done
