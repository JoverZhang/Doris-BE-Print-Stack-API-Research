#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$CASE_DIR"

rm -rf data tmp logs access user_files format_schemas outputs fp_control/build bin

if [[ "${1:-}" == "--cache" ]]; then
  rm -rf cache
fi
