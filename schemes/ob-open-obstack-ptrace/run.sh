#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCHEME_DIR"

mkdir -p commands

./commands/source_build_probe.sh > commands/source_build_probe.out
obstack_bin="$(awk -F= '/^binary_path_host=/{print $2}' commands/source_build_probe.out | tail -n 1)"

OBSTACK_BIN="$obstack_bin" ./commands/attach_synthetic.sh > commands/attach_synthetic.out
OBSTACK_BIN="$obstack_bin" ./commands/attach_observer.sh > commands/attach_observer.out
./minimal_impl/run.sh

for output in commands/source_build_probe.out commands/attach_synthetic.out commands/attach_observer.out; do
  if ! grep -q '^status=PASS$' "$output"; then
    echo "FAIL: $output did not report status=PASS." >&2
    exit 1
  fi
done

if ! grep -q '^status=PASS$' minimal_impl/ptrace_remote_unwind.out; then
  echo "FAIL: minimal_impl did not report status=PASS." >&2
  exit 1
fi
