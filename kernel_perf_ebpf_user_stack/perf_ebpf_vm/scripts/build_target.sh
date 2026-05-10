#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_cmd g++

g++ -std=c++17 -O2 -g -fno-omit-frame-pointer -fno-optimize-sibling-calls \
  "${CASE_DIR}/src/profile_target.cpp" \
  -pthread -lm -o "${TARGET_FP}"

g++ -std=c++17 -O2 -g -fomit-frame-pointer \
  "${CASE_DIR}/src/profile_target.cpp" \
  -pthread -lm -o "${TARGET_NOFP}"

{
  echo "fp_binary=${TARGET_FP}"
  echo "nofp_binary=${TARGET_NOFP}"
  echo "fp_build_flags=-O2 -g -fno-omit-frame-pointer -fno-optimize-sibling-calls"
  echo "nofp_build_flags=-O2 -g -fomit-frame-pointer"
} >"${RESULT_DIR}/build.txt"

log "built targets:"
log "  ${TARGET_FP}"
log "  ${TARGET_NOFP}"
