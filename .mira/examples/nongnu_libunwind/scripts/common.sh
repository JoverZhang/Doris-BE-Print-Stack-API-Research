#!/usr/bin/env bash

EXAMPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$EXAMPLE_ROOT/../../.." && pwd)"

LIBUNWIND_SRC="${LIBUNWIND_SRC:-$PROJECT_ROOT/.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind}"
OUT="$EXAMPLE_ROOT/out"
LIBUNWIND_COPY="$OUT/libunwind-src"
LIBUNWIND_BUILD="$OUT/libunwind-build"
LIBUNWIND_INSTALL="$OUT/libunwind-install"
BIN="$OUT/unwind_self"
FRAMES="$OUT/frames.tsv"
SYMBOLS_NM="$OUT/symbols.nm"
SYMBOLS_READELF="$OUT/symbols.readelf"

CC_BIN="${CC:-clang}"
CXX_BIN="${CXX:-clang++}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

fail() {
    echo "error: $*" >&2
    exit 1
}

need_tool() {
    command -v "$1" >/dev/null 2>&1 || fail "missing required tool: $1"
}

real_path() {
    readlink -f "$1"
}

hex_to_dec() {
    local value="${1#0x}"
    value="${value#0X}"
    echo $((16#$value))
}

require_linux_x86_64() {
    [[ "$(uname -s)" == "Linux" ]] || fail "this example targets Linux"
    [[ "$(uname -m)" == "x86_64" ]] || fail "this example targets x86_64"
}

libunwind_version() {
    awk '
        index($0, "define(pkg_major") { major=$2 }
        index($0, "define(pkg_minor") { minor=$2 }
        index($0, "define(pkg_extra") { extra=$2 }
        END {
            gsub(/[^0-9]/, "", major);
            gsub(/[^0-9]/, "", minor);
            gsub(/[^0-9]/, "", extra);
            print major "." minor "." extra
        }
    ' "$LIBUNWIND_SRC/configure.ac"
}
