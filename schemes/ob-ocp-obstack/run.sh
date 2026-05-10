#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCHEME_DIR"

./build.sh
set +e
./commands/obstack_collect.sh > commands/obstack_collect.out
rc=$?
set -e

if grep -q '^BLOCKED:' commands/obstack_collect.out; then
  echo "BLOCKED: OCP obstack provenance is recorded, but real observer collection is not produced." >&2
  exit 2
fi

if ! grep -q '^status=PASS$' commands/obstack_collect.out; then
  echo "FAIL: OCP obstack did not produce real observer stack output." >&2
  if [[ "$rc" -eq 0 ]]; then
    exit 1
  fi
  exit "$rc"
fi
