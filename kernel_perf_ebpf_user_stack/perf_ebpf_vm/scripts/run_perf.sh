#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_cmd perf

if [[ ! -x "${TARGET_FP}" || ! -x "${TARGET_NOFP}" ]]; then
  "${SCRIPT_DIR}/build_target.sh"
fi

relax_kernel_settings_for_vm
write_env_snapshot

run_child_case() {
  local label="$1"
  local target="$2"
  local graph="$3"
  local output="${RESULT_DIR}/perf_${label}_${graph}.data"

  log "perf child case: ${label}, callgraph=${graph}"
  perf record -q -F 99 -e cpu-clock:u --call-graph "${graph}" \
    -o "${output}" -- \
    "${target}" --cpu-threads 2 --sleep-threads 2 --blocked-threads 2 --seconds 6 \
    >"${RESULT_DIR}/target_${label}_${graph}.log" \
    2>"${RESULT_DIR}/perf_${label}_${graph}.stderr" || true

  postprocess_perf_data "${output}" "perf_${label}_${graph}"
  summarize_perf_script "${RESULT_DIR}/perf_${label}_${graph}.script" \
    "${RESULT_DIR}/perf_${label}_${graph}.summary"
}

run_attach_case() {
  local target="${TARGET_FP}"
  log "perf attach own-process case"
  "${target}" --cpu-threads 2 --sleep-threads 2 --blocked-threads 2 --seconds 10 \
    >"${RESULT_DIR}/target_attach.log" 2>"${RESULT_DIR}/target_attach.stderr" &
  local target_pid=$!
  sleep 1
  perf record -q -p "${target_pid}" -F 99 -e cpu-clock:u --call-graph fp,64 \
    -o "${RESULT_DIR}/perf_attach_fp.data" -- sleep 4 \
    >"${RESULT_DIR}/perf_attach_fp.stdout" \
    2>"${RESULT_DIR}/perf_attach_fp.stderr" || true
  wait "${target_pid}" || true
  postprocess_perf_data "${RESULT_DIR}/perf_attach_fp.data" "perf_attach_fp"
  summarize_perf_script "${RESULT_DIR}/perf_attach_fp.script" \
    "${RESULT_DIR}/perf_attach_fp.summary"
}

run_system_wide_case() {
  local target="${TARGET_FP}"
  log "perf system-wide case"
  "${target}" --cpu-threads 2 --sleep-threads 2 --blocked-threads 2 --seconds 10 \
    >"${RESULT_DIR}/target_system_wide.log" 2>"${RESULT_DIR}/target_system_wide.stderr" &
  local target_pid=$!
  sleep 1
  perf record -q -a -F 99 -e cpu-clock:u --call-graph dwarf,8192 \
    -o "${RESULT_DIR}/perf_system_wide_dwarf.data" -- sleep 4 \
    >"${RESULT_DIR}/perf_system_wide_dwarf.stdout" \
    2>"${RESULT_DIR}/perf_system_wide_dwarf.stderr" || true
  wait "${target_pid}" || true
  postprocess_perf_data "${RESULT_DIR}/perf_system_wide_dwarf.data" "perf_system_wide_dwarf"
  summarize_perf_script "${RESULT_DIR}/perf_system_wide_dwarf.script" \
    "${RESULT_DIR}/perf_system_wide_dwarf.summary"
}

run_child_case "fp" "${TARGET_FP}" "fp,64"
run_child_case "fp" "${TARGET_FP}" "dwarf,8192"
run_child_case "nofp" "${TARGET_NOFP}" "fp,64"
run_child_case "nofp" "${TARGET_NOFP}" "dwarf,8192"
run_attach_case
run_system_wide_case

{
  echo "perf run complete"
  for f in "${RESULT_DIR}"/perf_*.summary; do
    echo
    echo "== ${f##*/} =="
    sed -n '1,20p' "${f}"
  done
} >"${RESULT_DIR}/perf_summary.txt"

log "perf results: ${RESULT_DIR}"
