#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${SCRIPT_DIR}/build.sh" >/dev/null
"${SCRIPT_DIR}/build/profile_target_fp" \
  --cpu-threads 2 --sleep-threads 2 --blocked-threads 2 --seconds 2
