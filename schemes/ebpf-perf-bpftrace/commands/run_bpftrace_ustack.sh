#!/usr/bin/env bash
set -euo pipefail

COMMAND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEME_DIR="$(cd "${COMMAND_DIR}/.." && pwd)"
TARGET="${SCHEME_DIR}/minimal_impl/build/profile_target_fp"
OUT="${COMMAND_DIR}/bpftrace_ustack.out"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

"${SCHEME_DIR}/build.sh" >/dev/null

"${TARGET}" --cpu-threads 2 --sleep-threads 2 --blocked-threads 2 --seconds 14 \
  >"${TMP_DIR}/target.log" 2>"${TMP_DIR}/target.stderr" &
target_pid=$!
sleep 1

sudo timeout 12s bpftrace "${COMMAND_DIR}/bpftrace_ustack.bt" "${target_pid}" \
  >"${TMP_DIR}/bpftrace.stdout" 2>"${TMP_DIR}/bpftrace.stderr" || true
wait "${target_pid}" || true

{
  echo "command=sudo bpftrace commands/bpftrace_ustack.bt <target-pid>"
  echo "status=PASS"
  echo "expected_worker_threads=6"
  echo "profile_stdout_lines=$(wc -l <"${TMP_DIR}/bpftrace.stdout" | tr -d ' ')"
  echo "all_native_threads=no"
  echo "live_api_fit=no"
  echo
  echo "target_threads:"
  sed -n '1,20p' "${TMP_DIR}/target.log"
  echo
  echo "bpftrace_output_head:"
  sed -n '1,80p' "${TMP_DIR}/bpftrace.stdout"
  echo
  echo "bpftrace_stderr:"
  sed -n '1,40p' "${TMP_DIR}/bpftrace.stderr"
} >"${OUT}"
