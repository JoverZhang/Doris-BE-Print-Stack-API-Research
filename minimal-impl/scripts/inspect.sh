#!/usr/bin/env bash
# Pretty-print ELF + CFI info for a built binary. Combines readelf summary,
# elf_inspect's CFI classification, and a focused objdump slice.
set -euo pipefail

BIN="${1:-}"
if [[ -z "$BIN" || ! -x "$BIN" ]]; then
    echo "usage: $0 BINARY" >&2
    exit 2
fi

cd "$(dirname "$0")/.."

# elf_inspect is only built under release variants (see CMakeLists.txt).
# Pick whichever release_* build is available.
ELF_INSPECT=""
for candidate in build/release_fp/elf_inspect build/release_nofp/elf_inspect; do
    if [[ -x "$candidate" ]]; then
        ELF_INSPECT="$candidate"
        break
    fi
done

if [[ -z "$ELF_INSPECT" ]]; then
    echo "elf_inspect not found; run 'just build release_fp' first." >&2
    exit 1
fi

echo "============================================================"
echo " readelf -h (ELF header)"
echo "============================================================"
readelf -h "$BIN" | sed -n '1,12p'
echo

echo "============================================================"
echo " readelf -S (selected sections)"
echo "============================================================"
readelf -SW "$BIN" | awk 'NR==1||/\.text|\.eh_frame|\.debug_frame|\.symtab/'
echo

echo "============================================================"
echo " elf_inspect summary (workload functions only)"
echo "============================================================"
"$ELF_INSPECT" "$BIN" --filter 'workload::'
echo

echo "============================================================"
echo " elf_inspect detail: workload::level3"
echo "============================================================"
"$ELF_INSPECT" "$BIN" --func 'workload::level3' --filter ''
echo

echo "============================================================"
echo " objdump -d slice: workload::level3 (entry + 16 instructions)"
echo "============================================================"
objdump -d --no-show-raw-insn -M intel "$BIN" 2>/dev/null \
    | sed -n '/<.*workload.*level3.*>:/,/^$/p' \
    | head -25 || true
