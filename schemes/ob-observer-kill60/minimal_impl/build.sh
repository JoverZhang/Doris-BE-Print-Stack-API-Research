#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR"

mkdir -p build
c++ -std=c++17 -O2 -g -fno-omit-frame-pointer -pthread \
  observer_kill60_minimal.cpp \
  -lunwind -lunwind-x86_64 \
  -o build/observer_kill60_minimal
