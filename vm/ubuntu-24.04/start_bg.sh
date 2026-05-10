#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

pidfile="vm.pid"
logfile="vm.log"

if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" >/dev/null 2>&1; then
  echo "VM already running pid=$(cat "$pidfile")"
  exit 0
fi

nohup ./start.sh >"$logfile" 2>&1 &
echo "$!" >"$pidfile"
echo "started VM pid=$(cat "$pidfile") log=$logfile"

