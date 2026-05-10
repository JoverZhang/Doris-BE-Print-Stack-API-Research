#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$BASE_DIR/build"
mkdir -p "$BUILD_DIR"

c++ -std=c++17 -O1 -g -fno-omit-frame-pointer -pthread \
  "$BASE_DIR/target.cpp" -o "$BUILD_DIR/target"

if pkg-config --exists libunwind-ptrace; then
  c++ -std=c++17 -O1 -g -fno-omit-frame-pointer \
    "$BASE_DIR/ptrace_remote_unwind.cpp" -o "$BUILD_DIR/ptrace_remote_unwind" \
    $(pkg-config --cflags --libs libunwind-ptrace)
else
  c++ -std=c++17 -O1 -g -fno-omit-frame-pointer \
    "$BASE_DIR/ptrace_remote_unwind.cpp" -o "$BUILD_DIR/ptrace_remote_unwind" \
    -lunwind-ptrace -lunwind-x86_64 -lunwind
fi
