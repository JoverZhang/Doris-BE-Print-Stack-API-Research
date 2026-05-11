#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
"${SCRIPT_DIR}/build.sh" >/dev/null
"${REPO_ROOT}/shared/ebpf/profile_target/build/profile_target_fp" \
  --cpu-threads 2 --sleep-threads 2 --blocked-threads 2 --seconds 2 \
  >"${SCRIPT_DIR}/profile_target.out"
