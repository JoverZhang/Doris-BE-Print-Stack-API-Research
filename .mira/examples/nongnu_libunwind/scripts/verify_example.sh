#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=common.sh
source "$ROOT/scripts/common.sh"

need_tool nm
need_tool readelf
need_tool objdump
need_tool addr2line
require_linux_x86_64

[[ -x "$BIN" ]] || fail "missing binary: $BIN"
[[ -s "$FRAMES" ]] || fail "missing frames output: $FRAMES"
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
