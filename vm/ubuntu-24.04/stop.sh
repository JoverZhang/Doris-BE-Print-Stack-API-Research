#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
pidfile="vm.pid"

if [[ ! -f "$pidfile" ]]; then
  echo "VM pidfile not found"
  exit 0
fi

pid="$(cat "$pidfile")"
if kill -0 "$pid" >/dev/null 2>&1; then
  kill "$pid"
  for _ in $(seq 1 30); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      rm -f "$pidfile"
      echo "stopped VM"
      exit 0
    fi
    sleep 1
  done
  kill -9 "$pid" >/dev/null 2>&1 || true
fi

rm -f "$pidfile"
echo "stopped VM"
