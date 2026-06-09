#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=common.sh
source "$ROOT/scripts/common.sh"

need_tool "$CXX_BIN"
require_linux_x86_64

mapfile -t unwind_archives < <(
    find "$LIBUNWIND_INSTALL" -type f \( -name 'libunwind.a' -o -name 'libunwind-x86_64.a' \) | sort
)
(( ${#unwind_archives[@]} > 0 )) || fail "libunwind static archives were not installed"

cxxflags=(
    -std=c++20
    -O3
    -DNDEBUG
    -g
    -gdwarf-5
    -gdwarf-aranges
    -Wall
    -Wextra
    -Werror
    -pthread
    -fstrict-aliasing
    -fno-omit-frame-pointer
    -msse4.2
)

rm -f "$BIN" "$FRAMES" "$SYMBOLS_NM" "$SYMBOLS_READELF" "$OUT"/objdump-*.txt

echo "building example: $BIN"
"$CXX_BIN" "${cxxflags[@]}" \
    -I"$LIBUNWIND_INSTALL/include" \
    "$EXAMPLE_ROOT/unwind_self.cpp" \
    "$EXAMPLE_ROOT/dso_resolver.cpp" \
    -Wl,--start-group "${unwind_archives[@]}" -Wl,--end-group \
    -llzma -ldl -pthread \
    -o "$BIN"
