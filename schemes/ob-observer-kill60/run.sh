#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCHEME_DIR"

mkdir -p commands

if [[ -n "${OBSERVER_BIN:-}" && -x "${OBSERVER_BIN:-}" ]]; then
  OBSERVER_BIN="$OBSERVER_BIN" ./commands/observer_kill60.sh > commands/observer_kill60.out
elif observer_bin="$(./build.sh | tail -n 1)"; then
  OBSERVER_BIN="$observer_bin" ./commands/observer_kill60.sh > commands/observer_kill60.out
else
  ./commands/observer_kill60.sh > commands/observer_kill60.out || true
fi

if [[ "${SKIP_MINIMAL:-0}" != "1" ]]; then
  ./minimal_impl/run.sh
fi

if grep -q '^BLOCKED:' commands/observer_kill60.out; then
  echo "BLOCKED: real observer run was not produced; minimal_impl output was refreshed." >&2
  exit 2
fi
