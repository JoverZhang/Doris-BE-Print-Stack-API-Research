#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

RUN_INSTALL_DEPS="${RUN_INSTALL_DEPS:-0}"
RUN_INDUSTRY="${RUN_INDUSTRY:-1}"

if [[ "${RUN_INSTALL_DEPS}" == "1" ]]; then
  "${SCRIPT_DIR}/install_deps.sh"
fi

"${SCRIPT_DIR}/build_target.sh"
"${SCRIPT_DIR}/run_perf.sh"
"${SCRIPT_DIR}/run_bpftrace.sh"

if [[ "${RUN_INDUSTRY}" == "1" ]]; then
  "${SCRIPT_DIR}/run_industry_profiler.sh"
fi

{
  echo "task20 run_all complete"
  echo "result_dir=${RESULT_DIR}"
  echo
  for f in environment.txt build.txt perf_summary.txt bpftrace_summary.txt industry_profiler_summary.txt; do
    if [[ -f "${RESULT_DIR}/${f}" ]]; then
      echo "== ${f} =="
      sed -n '1,120p' "${RESULT_DIR}/${f}"
      echo
    fi
  done
} >"${RESULT_DIR}/run_all_summary.txt"

log "all results: ${RESULT_DIR}"
