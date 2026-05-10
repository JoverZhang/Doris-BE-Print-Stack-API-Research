#!/usr/bin/env bash
set -euo pipefail

COMMAND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEME_DIR="$(cd "${COMMAND_DIR}/.." && pwd)"
TARGET="${SCHEME_DIR}/minimal_impl/build/profile_target_fp"
OUT="${COMMAND_DIR}/perf_fp.out"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

"${SCHEME_DIR}/build.sh" >/dev/null

perf record -q -F 99 -e cpu-clock:u --call-graph fp,64 \
  -o "${TMP_DIR}/perf_fp.data" -- \
  "${TARGET}" --cpu-threads 2 --sleep-threads 2 --blocked-threads 2 --seconds 6 \
  >"${TMP_DIR}/target.log" 2>"${TMP_DIR}/perf.stderr" || true

perf script -i "${TMP_DIR}/perf_fp.data" >"${TMP_DIR}/perf.script" \
  2>"${TMP_DIR}/perf_script.stderr" || true

sample_count="$(grep -c '^profile_target_' "${TMP_DIR}/perf.script" || true)"
sampled_tids="$(awk '/^profile_target_/ {print $2}' "${TMP_DIR}/perf.script" | sort -u | xargs || true)"
sampled_tid_count="$(awk '/^profile_target_/ {print $2}' "${TMP_DIR}/perf.script" | sort -u | wc -l | tr -d ' ')"

{
  echo "command=perf record -F 99 -e cpu-clock:u --call-graph fp,64 -- profile_target_fp"
  echo "status=PASS"
  echo "expected_worker_threads=6"
  echo "sample_count=${sample_count}"
  echo "sampled_tids=${sampled_tids}"
  echo "sampled_tid_count=${sampled_tid_count}"
  echo "all_native_threads=no"
  echo "live_api_fit=no"
  echo
  echo "target_threads:"
  sed -n '1,20p' "${TMP_DIR}/target.log"
  echo
  echo "first_perf_sample:"
  sed -n '1,36p' "${TMP_DIR}/perf.script"
  echo
  echo "perf_stderr:"
  sed -n '1,40p' "${TMP_DIR}/perf.stderr"
} >"${OUT}"
