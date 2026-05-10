#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR"

./build.sh
rm -f minimal.pid stack.* observer_kill60_minimal.out

./build/observer_kill60_minimal > observer_kill60_minimal.program.out 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do
  [[ -f minimal.pid ]] && break
  sleep 0.1
done

if [[ ! -f minimal.pid ]]; then
  echo "status=FAIL reason=minimal.pid not created" > observer_kill60_minimal.out
  exit 1
fi

target_pid="$(cat minimal.pid)"
kill -60 "$target_pid"
wait "$pid"
trap - EXIT

stack_file="$(ls -1t stack."$target_pid".* 2>/dev/null | head -n 1 || true)"
{
  echo "command=kill -60 <minimal-pid>"
  if [[ -n "$stack_file" ]]; then
    echo "status=PASS"
    echo "stack_file=stack.<minimal-pid>.<timestamp>"
    echo
    echo "program_stdout:"
    sed "s#$BASE_DIR#<minimal-dir>#g; s#$target_pid#<minimal-pid>#g" observer_kill60_minimal.program.out
    echo
    echo "maps_head:"
    sed -n '1,12p' "$stack_file" | sed "s#$BASE_DIR#<minimal-dir>#g"
    echo
    echo "thread_stack_lines:"
    grep '^tid:' "$stack_file" | sed "s#$BASE_DIR#<minimal-dir>#g"
  else
    echo "status=FAIL"
    echo "reason=no stack file"
    sed "s#$BASE_DIR#<minimal-dir>#g" observer_kill60_minimal.program.out
  fi
} > observer_kill60_minimal.out

cat observer_kill60_minimal.out
