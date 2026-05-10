#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCHEME_DIR"

mkdir -p commands

if observer_bin="$(./build.sh | tail -n 1)"; then
  OBSERVER_BIN="$observer_bin" ./commands/observer_kill60.sh > commands/observer_kill60.out
else
  ./commands/observer_kill60.sh > commands/observer_kill60.out || true
fi

./minimal_impl/run.sh

if grep -q '^BLOCKED:' commands/observer_kill60.out; then
  echo "BLOCKED: real observer run was not produced; minimal_impl output was refreshed." >&2
  exit 2
fi
