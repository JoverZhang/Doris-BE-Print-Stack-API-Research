#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$CASE_DIR"

OUT_DIR="outputs/fp_control"
BUILD_DIR="fp_control/build"
SRC="fp_control/backend_control.cpp"
mkdir -p "$OUT_DIR" "$BUILD_DIR"
rm -f "${OUT_DIR}"/*

CXX="${CXX:-g++}"
COMMON_FLAGS=(-std=c++17 -O2 -g -rdynamic -no-pie -fno-optimize-sibling-calls)
COMMON_LIBS=(-lunwind -lunwind-x86_64 -ldl)

"${CXX}" "${COMMON_FLAGS[@]}" -fno-omit-frame-pointer "$SRC" \
  -o "${BUILD_DIR}/backend_control.fp" "${COMMON_LIBS[@]}"
"${CXX}" "${COMMON_FLAGS[@]}" -fomit-frame-pointer "$SRC" \
  -o "${BUILD_DIR}/backend_control.no_fp" "${COMMON_LIBS[@]}"

run_one() {
  local tag="$1"
  local bin="$2"
  "${bin}" > "${OUT_DIR}/${tag}.stdout.txt" 2> "${OUT_DIR}/${tag}.stderr.txt"
  local exit_code=$?
  echo "${tag},${exit_code}" >> "${OUT_DIR}/run_status.csv"
  awk -F= '/^(frame_pointer_pc|libunwind_pc)\[[0-9]+\]=0x/ {
    split($1, key, "[");
    kind=key[1];
    pc=$2;
    sub(/ .*/, "", pc);
    print kind, pc;
  }' "${OUT_DIR}/${tag}.stdout.txt" | while read -r kind pc; do
    echo "${kind} ${pc}"
    addr2line -f -C -e "$bin" "$pc" || true
  done > "${OUT_DIR}/${tag}.addr2line.txt"
}

echo "case,exit_code" > "${OUT_DIR}/run_status.csv"
run_one "fp_enabled" "${BUILD_DIR}/backend_control.fp"
run_one "fp_omitted" "${BUILD_DIR}/backend_control.no_fp"

{
  echo "case,frame_pointer_depth,libunwind_depth"
  for tag in fp_enabled fp_omitted; do
    fp_depth="$(sed -n 's/^frame_pointer_depth=//p' "${OUT_DIR}/${tag}.stdout.txt")"
    unwind_depth="$(sed -n 's/^libunwind_depth=//p' "${OUT_DIR}/${tag}.stdout.txt")"
    echo "${tag},${fp_depth},${unwind_depth}"
  done
} > "${OUT_DIR}/depth_summary.csv"

echo "FP/no-FP backend control outputs written under ${OUT_DIR}"
