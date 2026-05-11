#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
mkdir -p "${BUILD_DIR}"

c++ -std=c++17 -O2 -g -fno-omit-frame-pointer -pthread \
  "${SCRIPT_DIR}/profile_target.cpp" -lm -o "${BUILD_DIR}/profile_target_fp"

c++ -std=c++17 -O2 -g -fomit-frame-pointer -pthread \
  "${SCRIPT_DIR}/profile_target.cpp" -lm -o "${BUILD_DIR}/profile_target_nofp"
