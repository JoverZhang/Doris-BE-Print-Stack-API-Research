#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR"

./build.sh
rm -f ptrace_remote_unwind.out ptrace_remote_unwind.raw target.program.out

./build/ptrace_remote_unwind ./build/target > ptrace_remote_unwind.raw 2>&1

{
  echo "command=ptrace_remote_unwind <target-program>"
  echo "status=PASS"
  echo
  sed -E \
    -e "s#$BASE_DIR#<minimal-dir>#g" \
    -e 's/pid=[0-9]+/pid=<target-pid>/g' \
    -e 's/target_pid=[0-9]+/target_pid=<target-pid>/g' \
    -e 's/target_tid=[0-9]+/target_tid=<tid>/g' \
    -e 's/thread=[0-9]+/thread=<tid>/g' \
    -e 's/tid=[0-9]+/tid=<tid>/g' \
    -e 's/sink=[0-9]+/sink=<value>/g' \
    ptrace_remote_unwind.raw
} > ptrace_remote_unwind.out

cat ptrace_remote_unwind.out
