#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
obstack_bin="${OBSTACK_BIN:-}"

if [[ -z "$obstack_bin" || ! -x "$obstack_bin" ]]; then
  cat <<'OUT'
BLOCKED: source-built open obstack binary is unavailable.
See commands/source_build_probe.out for the current source-build blocker.
The source-derived minimal_impl proves the ptrace/libunwind-ptrace mechanics, but it is not substituted for this open obstack project-run output.
OUT
  exit 2
fi

"$SCHEME_DIR/minimal_impl/build.sh" >/dev/null
"$SCHEME_DIR/minimal_impl/build/target" > "$SCHEME_DIR/minimal_impl/target.program.out" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT

sleep 1

echo "command=${obstack_bin} -n ${pid}"
echo "target_pid=${pid}"
"$obstack_bin" -n "$pid"
