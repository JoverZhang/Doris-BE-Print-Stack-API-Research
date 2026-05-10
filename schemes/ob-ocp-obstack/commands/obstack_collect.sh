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
Start the source-built OceanBase observer first, then rerun with OBSERVER_PID=<pid>.
OUT
  exit 2
fi

echo "command=${bin} -o ${observer_pid}"
tmp_dir="${TMPDIR:-$SCHEME_DIR/tmp}/obstack_collect.$$"
mkdir -p "$tmp_dir"
raw="$tmp_dir/obstack.raw"
stderr_file="$tmp_dir/obstack.stderr"

set +e
"$bin" -o "$observer_pid" >"$raw" 2>"$stderr_file"
rc=$?
set -e

raw_bytes="$(wc -c <"$raw")"
stderr_bytes="$(wc -c <"$stderr_file")"
ptrace_denied_lines="$(grep -c 'Operation not permitted' "$stderr_file" || true)"

echo "exit_code=${rc}"
echo "obstack_output_bytes=${raw_bytes}"
echo "obstack_stderr_bytes=${stderr_bytes}"
echo "ptrace_denied_lines=${ptrace_denied_lines}"

if [[ "$raw_bytes" -gt 0 ]]; then
  echo "status=PASS"
  echo "obstack_output_lines=$(wc -l <"$raw")"
  echo
  echo "obstack_stderr_sample:"
  sed -n '1,40p' "$stderr_file"
  echo
  echo "obstack_stdout_sample:"
  sed -n '1,120p' "$raw"
  exit 0
fi

echo "status=FAIL"
echo "reason=OCP obstack produced no stdout stack output."
echo
echo "obstack_stderr_sample:"
sed -n '1,120p' "$stderr_file"
exit 1
