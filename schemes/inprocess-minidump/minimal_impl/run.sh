#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$DIR" rev-parse --show-toplevel)"
CMAKE_PRESET="${CMAKE_PRESET:-debug}"
CMAKE_BUILD_PRESET="${CMAKE_BUILD_PRESET:-$CMAKE_PRESET}"

(cd "$REPO_ROOT" && cmake --preset "$CMAKE_PRESET" >/dev/null)
(cd "$REPO_ROOT" && cmake --build --preset "$CMAKE_BUILD_PRESET" --target inprocess_minidump >/dev/null)

cd "$DIR"
./build/inprocess_minidump > inprocess_minidump.out

grep -q '^scheme=inprocess-minidump$' inprocess_minidump.out
grep -q '^arch=x86_64$' inprocess_minidump.out
grep -q '^compile_frame_pointer_flag=default_no_fno_omit_frame_pointer$' inprocess_minidump.out
grep -q '^capture_result slot=0 ok=yes$' inprocess_minidump.out
grep -q '^capture_result slot=1 ok=yes$' inprocess_minidump.out
test "$(grep -c '^unwind_status=OK frames=' inprocess_minidump.out)" -eq 2

cat inprocess_minidump.out
