#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

./build.sh
./build/safe_with_phdr_cache > safe_with_phdr_cache.out

grep -q '^status=PASS$' safe_with_phdr_cache.out
grep -Eq '^cache_path_calls=[1-9][0-9]*$' safe_with_phdr_cache.out

cat safe_with_phdr_cache.out
