#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$ROOT/../../.." && pwd)"

LIBUNWIND_SRC="${LIBUNWIND_SRC:-$PROJECT_ROOT/.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind}"
OUT="$ROOT/out"
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

need_tool "$CC_BIN"
need_tool "$CXX_BIN"
need_tool autoreconf
need_tool make
need_tool tar
need_tool nm
need_tool readelf
need_tool objdump
need_tool addr2line

[[ "$(uname -s)" == "Linux" ]] || fail "this example targets Linux"
[[ "$(uname -m)" == "x86_64" ]] || fail "this example targets x86_64"
[[ -f "$LIBUNWIND_SRC/configure.ac" ]] || fail "missing libunwind source: $LIBUNWIND_SRC"

mkdir -p "$OUT"
rm -rf "$LIBUNWIND_COPY" "$LIBUNWIND_BUILD" "$LIBUNWIND_INSTALL" "$BIN" "$FRAMES" \
       "$SYMBOLS_NM" "$SYMBOLS_READELF" "$OUT"/objdump-*.txt
mkdir -p "$LIBUNWIND_COPY" "$LIBUNWIND_BUILD" "$LIBUNWIND_INSTALL/include" "$LIBUNWIND_INSTALL/lib"

version="$(
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
)"
echo "libunwind source: $LIBUNWIND_SRC"
echo "libunwind version: $version"

(
    cd "$LIBUNWIND_SRC"
    tar --exclude=.git -cf - .
) | (
    cd "$LIBUNWIND_COPY"
    tar -xf -
)

autoreconf_log="$OUT/autoreconf.log"
echo "running autoreconf (log: $autoreconf_log)"
(
    cd "$LIBUNWIND_COPY"
    autoreconf -i
) > "$autoreconf_log" 2>&1 || {
    tail -n 80 "$autoreconf_log" >&2
    fail "autoreconf failed"
}

libunwind_cflags=(
    "-I$LIBUNWIND_INSTALL/include"
    "-std=c99"
    "-D_LIBUNWIND_NO_HEAP=1"
    "-D_DEBUG"
    "-D_LIBUNWIND_IS_NATIVE_ONLY"
    "-O3"
    "-fno-exceptions"
    "-funwind-tables"
    "-fno-sanitize=all"
    "-nostdinc++"
    "-fno-rtti"
    "-Wno-error=incompatible-pointer-types"
)

build_log="$OUT/libunwind-build.log"
echo "building libunwind (log: $build_log)"
(
    cd "$LIBUNWIND_BUILD"
    CC="$CC_BIN" \
    CXX="$CXX_BIN" \
    CFLAGS="${libunwind_cflags[*]}" \
    LDFLAGS="-llzma" \
    "$LIBUNWIND_COPY/configure" \
        --prefix="$LIBUNWIND_INSTALL" \
        --disable-shared \
        --enable-static \
        --disable-tests \
        --disable-documentation
    make -j"$JOBS"
    make install
) > "$build_log" 2>&1 || {
    tail -n 120 "$build_log" >&2
    fail "libunwind build failed"
}

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

"$CXX_BIN" "${cxxflags[@]}" \
    -I"$LIBUNWIND_INSTALL/include" \
    "$ROOT/unwind_self.cpp" \
    -Wl,--start-group "${unwind_archives[@]}" -Wl,--end-group \
    -llzma -ldl -pthread \
    -o "$BIN"

"$BIN" > "$FRAMES"
grep -q $'^FRAME\t' "$FRAMES" || fail "example did not print any FRAME rows"

nm -anS --defined-only "$BIN" > "$SYMBOLS_NM"
readelf -Ws "$BIN" > "$SYMBOLS_READELF"

required_symbols=(lw_capture_self_stack lw_level3 lw_level2 lw_level1 main)
for symbol in "${required_symbols[@]}"; do
    awk -v symbol="$symbol" '$4 == symbol && $2 != "0000000000000000" { found=1 } END { exit found ? 0 : 1 }' \
        "$SYMBOLS_NM" || fail "nm did not find nonzero symbol: $symbol"

    awk -v symbol="$symbol" '$4 == "FUNC" && $8 == symbol && $3 > 0 { found=1 } END { exit found ? 0 : 1 }' \
        "$SYMBOLS_READELF" || fail "readelf did not find nonzero FUNC symbol: $symbol"
done

for symbol in lw_level1 lw_level2 lw_level3; do
    objdump_file="$OUT/objdump-$symbol.txt"
    objdump -dr --disassemble="$symbol" "$BIN" > "$objdump_file"
    grep -Eq '\bcallq?\b' "$objdump_file" || fail "no real call instruction found in $symbol"
done

declare -A symbol_start=()
declare -A symbol_end=()
while read -r name value size; do
    [[ -n "$name" ]] || continue
    start=$((16#$value))
    end=$((start + size))
    symbol_start["$name"]="$start"
    symbol_end["$name"]="$end"
done < <(
    awk '
        $4 == "FUNC" && $3 > 0 &&
        ($8 == "lw_capture_self_stack" || $8 == "lw_level3" || $8 == "lw_level2" || $8 == "lw_level1" || $8 == "main") {
            print $8, $2, $3
        }
    ' "$SYMBOLS_READELF"
)

for symbol in "${required_symbols[@]}"; do
    [[ -n "${symbol_start[$symbol]:-}" ]] || fail "missing symbol range: $symbol"
done

declare -A seen=()
bin_real="$(real_path "$BIN")"
while IFS=$'\t' read -r tag index pc dso dso_offset proc_name; do
    [[ "$tag" == "FRAME" ]] || continue
    [[ -n "${index:-}" && -n "${pc:-}" && -n "${dso:-}" && -n "${dso_offset:-}" && -n "${proc_name:-}" ]] \
        || fail "malformed FRAME row: $tag $index $pc $dso $dso_offset $proc_name"

    dso_real=""
    if [[ "$dso" == "$bin_real" ]]; then
        dso_real="$bin_real"
    elif [[ -e "$dso" ]]; then
        dso_real="$(real_path "$dso")"
    fi
    [[ "$dso_real" == "$bin_real" ]] || continue

    offset_dec="$(hex_to_dec "$dso_offset")"
    for symbol in "${required_symbols[@]}"; do
        if (( offset_dec >= symbol_start[$symbol] && offset_dec < symbol_end[$symbol] )); then
            seen["$symbol"]="$dso_offset"
        fi
    done
done < "$FRAMES"

for symbol in "${required_symbols[@]}"; do
    [[ -n "${seen[$symbol]:-}" ]] || fail "captured frames do not include $symbol in binary DSO"
    echo "verified frame: $symbol @ ${seen[$symbol]}"
    addr2line -f -C -e "$BIN" "${seen[$symbol]}"
done

echo
echo "OK"
echo "binary: $BIN"
echo "frames: $FRAMES"
echo "symbols: $SYMBOLS_NM"
