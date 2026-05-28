#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

pidfile="vm.pid"
logfile="vm.log"

if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" >/dev/null 2>&1; then
  echo "VM already running pid=$(cat "$pidfile")"
  exit 0
fi

rm -f "$pidfile" "$logfile"
VM_DAEMONIZE=1 VM_PIDFILE="$pidfile" VM_LOGFILE="$logfile" ./start.sh
echo "started VM pid=$(cat "$pidfile") log=$logfile"
