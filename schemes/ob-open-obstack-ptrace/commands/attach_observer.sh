#!/usr/bin/env bash
set -euo pipefail

obstack_bin="${OBSTACK_BIN:-}"
observer_pid="${OBSERVER_PID:-}"

if [[ -z "$obstack_bin" || ! -x "$obstack_bin" ]]; then
  cat <<'OUT'
BLOCKED: source-built open obstack binary is unavailable.
See commands/source_build_probe.out for the current source-build blocker.
OUT
  exit 2
fi

if [[ -z "$observer_pid" ]]; then
  cat <<'OUT'
BLOCKED: OBSERVER_PID is not set.
The real observer source-build/run is blocked in scheme ob-observer-kill60, so no real observer attach output is produced here.
OUT
  exit 2
fi

echo "command=${obstack_bin} ${observer_pid}"
"$obstack_bin" "$observer_pid"
