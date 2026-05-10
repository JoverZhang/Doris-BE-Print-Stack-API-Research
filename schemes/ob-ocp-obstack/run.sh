#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCHEME_DIR"

./build.sh
./commands/obstack_collect.sh > commands/obstack_collect.out || true

if grep -q '^BLOCKED:' commands/obstack_collect.out; then
  echo "BLOCKED: OCP obstack provenance is recorded, but real observer collection is not produced." >&2
  exit 2
fi
