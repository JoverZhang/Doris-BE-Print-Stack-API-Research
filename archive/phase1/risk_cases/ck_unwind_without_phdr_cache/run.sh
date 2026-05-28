#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

./run_unsafe_no_phdr_cache.sh
echo
./run_safe_with_phdr_cache.sh
