#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCHEME_DIR"

mkdir -p commands

if obstack_bin="$(./build.sh | tail -n 1)"; then
  OBSTACK_BIN="$obstack_bin" ./commands/attach_synthetic.sh > commands/attach_synthetic.out
else
  ./commands/attach_synthetic.sh > commands/attach_synthetic.out || true
fi

./commands/attach_observer.sh > commands/attach_observer.out || true
./minimal_impl/run.sh

if grep -q '^BLOCKED:' commands/attach_synthetic.out || grep -q '^BLOCKED:' commands/attach_observer.out; then
  echo "BLOCKED: source-built open obstack/observer run was not produced; minimal_impl output was refreshed." >&2
  exit 2
fi
