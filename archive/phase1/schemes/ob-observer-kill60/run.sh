#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCHEME_DIR" rev-parse --show-toplevel)"
cd "$SCHEME_DIR"

mkdir -p commands

append_symbolized_sample() {
  local observer_bin="$1"
  local stack_file
  stack_file="$(sed -n 's/^stack_file=//p' commands/observer_kill60.out | tail -n 1)"
  if [[ -z "$stack_file" ]]; then
    return 0
  fi

  local stack_path="$SCHEME_DIR/tmp/observer-kill60/$stack_file"
  {
    echo
    python3 "$SCHEME_DIR/helpers/symbolize_stack.py" \
      --stack-file "$stack_path" \
      --main-binary "$observer_bin" \
      --repo-root "$REPO_ROOT" \
      --display-prefix "/work=<repo>" \
      --limit-threads "${OB_KILL60_SYMBOLIZE_THREADS:-5}" \
      --limit-frames "${OB_KILL60_SYMBOLIZE_FRAMES:-12}"
  } >> commands/observer_kill60.out
}

if [[ -n "${OBSERVER_BIN:-}" && -x "${OBSERVER_BIN:-}" ]]; then
  OBSERVER_BIN="$OBSERVER_BIN" ./commands/observer_kill60.sh > commands/observer_kill60.out
  append_symbolized_sample "$OBSERVER_BIN"
elif observer_bin="$(./build.sh | tail -n 1)"; then
  OBSERVER_BIN="$observer_bin" ./commands/observer_kill60.sh > commands/observer_kill60.out
  append_symbolized_sample "$observer_bin"
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
