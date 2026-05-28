#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

timeout_seconds="${VM_WAIT_SECONDS:-300}"
deadline=$((SECONDS + timeout_seconds))

while (( SECONDS < deadline )); do
  if ./ssh.sh true >/dev/null 2>&1; then
    ./ssh.sh 'echo "ssh-ready $(hostname) $(uname -r)"'
    exit 0
  fi
  sleep 5
done

echo "timed out waiting for VM SSH after ${timeout_seconds}s" >&2
exit 1

