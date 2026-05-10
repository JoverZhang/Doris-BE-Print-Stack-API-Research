#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

mkdir -p build
${CXX:-g++} -std=c++17 -O2 -g -rdynamic -fno-omit-frame-pointer \
  directed_signal_unwind.cpp -o build/directed_signal_unwind \
  -lunwind -lunwind-x86_64

./build/directed_signal_unwind > directed_signal_unwind.out
cat directed_signal_unwind.out
