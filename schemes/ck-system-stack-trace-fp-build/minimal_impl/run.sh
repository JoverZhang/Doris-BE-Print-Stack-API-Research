#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

mkdir -p build
CXX="${CXX:-g++}"
COMMON=(-std=c++17 -O2 -g -rdynamic -no-pie -fno-optimize-sibling-calls fp_vs_unwind.cpp -lunwind -lunwind-x86_64 -ldl)

"$CXX" -fno-omit-frame-pointer "${COMMON[@]}" -o build/fp_vs_unwind.fp
"$CXX" -fomit-frame-pointer "${COMMON[@]}" -o build/fp_vs_unwind.no_fp

{
  echo "case=fp_enabled"
  ./build/fp_vs_unwind.fp
  echo
  echo "case=fp_omitted"
  ./build/fp_vs_unwind.no_fp
} > fp_vs_unwind.out

cat fp_vs_unwind.out
