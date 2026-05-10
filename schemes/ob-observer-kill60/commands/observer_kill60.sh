#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCHEME_DIR"

observer="${OBSERVER_BIN:-}"
if [[ -z "$observer" || ! -x "$observer" ]]; then
  cat <<'OUT'
BLOCKED: source-built observer binary is unavailable.
See commands/source_build_probe.out for the current source-build blocker.
No release binary or synthetic target is used for this real-observer output.
OUT
  exit 2
fi

run_dir="$SCHEME_DIR/tmp/observer-kill60"
rm -rf "$run_dir"
mkdir -p "$run_dir"
cd "$run_dir"

"$observer" -P 2881 -p 2882 -z zone1 -n repro -c 1 -d "$run_dir/store" -i lo -o "memory_limit=6G,system_memory=2G,datafile_size=2G,log_disk_size=2G" > observer.stdout 2> observer.stderr &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT

for _ in $(seq 1 120); do
  if kill -0 "$pid" 2>/dev/null && [[ -f run/observer.pid ]]; then
    break
  fi
  sleep 1
done

if [[ ! -f run/observer.pid ]]; then
  echo "FAIL: observer did not create run/observer.pid"
  sed -n '1,80p' observer.stderr || true
  exit 2
fi

observer_pid="$(cat run/observer.pid)"
kill -60 "$observer_pid"

for _ in $(seq 1 60); do
  stack_file="$(ls -1t stack."$observer_pid".* 2>/dev/null | head -n 1 || true)"
  [[ -n "$stack_file" ]] && break
  sleep 1
done

if [[ -z "${stack_file:-}" ]]; then
  echo "FAIL: kill -60 did not produce stack file for observer pid=$observer_pid"
  sed -n '1,120p' observer.stderr || true
  exit 2
fi

echo "status=PASS"
echo "observer_pid=$observer_pid"
echo "stack_file=$stack_file"
sed -n '1,80p' "$stack_file"
