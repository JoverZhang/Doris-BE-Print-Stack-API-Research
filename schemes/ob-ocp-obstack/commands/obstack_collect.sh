#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="${OCP_OBSTACK_BIN:-$SCHEME_DIR/.cache/rpm-el8/usr/bin/obstack}"
observer_pid="${OBSERVER_PID:-}"

if [[ ! -x "$bin" ]]; then
  cat <<'OUT'
BLOCKED: OCP obstack binary is unavailable.
Run commands/provenance_probe.sh first or set OCP_OBSTACK_BIN.
OUT
  exit 2
fi

if [[ -z "$observer_pid" ]]; then
  cat <<'OUT'
BLOCKED: OBSERVER_PID is not set.
The real observer source-build/run is blocked in scheme ob-observer-kill60, so OCP obstack behavior against a real observer is not produced.
Package provenance is recorded in commands/provenance_probe.out only.
OUT
  exit 2
fi

echo "command=${bin} -o ${observer_pid}"
"$bin" -o "$observer_pid"
