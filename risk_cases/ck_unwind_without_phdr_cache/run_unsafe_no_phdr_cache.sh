#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

./build.sh
set +e
{
  timeout --kill-after=1s 3s ./build/unsafe_no_phdr_cache > unsafe_no_phdr_cache.raw 2>&1
  status=$?
} 2>/dev/null
set -e

cat unsafe_no_phdr_cache.raw > unsafe_no_phdr_cache.out
if [[ "$status" == "124" || "$status" == "137" || "$status" == "143" ]]; then
  {
    echo "status=EXPECTED_TIMEOUT"
    echo "reason=handler_unwind_reentered_slow_dl_iterate_phdr_while_loader_lock_was_held"
  } >> unsafe_no_phdr_cache.out
else
  echo "status=FAIL" >> unsafe_no_phdr_cache.out
  echo "reason=unsafe_binary_exited_without_timeout exit_code=$status" >> unsafe_no_phdr_cache.out
fi

grep -q '^status=EXPECTED_TIMEOUT$' unsafe_no_phdr_cache.out
grep -q '^handler_entered=yes$' unsafe_no_phdr_cache.out
grep -q '^dl_iterate_phdr_reentered_while_lock_held=yes$' unsafe_no_phdr_cache.out

cat unsafe_no_phdr_cache.out
