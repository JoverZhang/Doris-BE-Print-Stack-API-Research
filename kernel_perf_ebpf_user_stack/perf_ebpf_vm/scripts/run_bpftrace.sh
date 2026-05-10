#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_cmd bpftrace

if [[ ! -x "${TARGET_FP}" ]]; then
  "${SCRIPT_DIR}/build_target.sh"
fi

relax_kernel_settings_for_vm
write_env_snapshot

if ! is_root; then
  log "bpftrace normally requires root/CAP_BPF/CAP_PERFMON; continuing to capture the blocker"
fi

"${TARGET_FP}" --cpu-threads 2 --sleep-threads 2 --blocked-threads 2 --seconds 14 \
  >"${RESULT_DIR}/target_bpftrace.log" 2>"${RESULT_DIR}/target_bpftrace.stderr" &
target_pid=$!
sleep 1

log "bpftrace on-CPU profile ustack for pid=${target_pid}"
timeout 12s bpftrace "${CASE_DIR}/bpftrace/profile_ustack.bt" "${target_pid}" \
  >"${RESULT_DIR}/bpftrace_profile_ustack.stdout" \
  2>"${RESULT_DIR}/bpftrace_profile_ustack.stderr" || true

log "bpftrace sched_switch/off-CPU ustack for profile_target_* comm"
timeout 12s bpftrace "${CASE_DIR}/bpftrace/offcpu_sched_switch.bt" \
  >"${RESULT_DIR}/bpftrace_offcpu_sched_switch.stdout" \
  2>"${RESULT_DIR}/bpftrace_offcpu_sched_switch.stderr" || true

wait "${target_pid}" || true

{
  echo "target_pid=${target_pid}"
  echo "target_threads:"
  sed -n '1,40p' "${RESULT_DIR}/target_bpftrace.log"
  echo
  echo "profile_stdout_lines=$(wc -l <"${RESULT_DIR}/bpftrace_profile_ustack.stdout" 2>/dev/null || echo 0)"
  echo "profile_stderr:"
  sed -n '1,40p' "${RESULT_DIR}/bpftrace_profile_ustack.stderr" || true
  echo
  echo "offcpu_stdout_lines=$(wc -l <"${RESULT_DIR}/bpftrace_offcpu_sched_switch.stdout" 2>/dev/null || echo 0)"
  echo "offcpu_stderr:"
  sed -n '1,40p' "${RESULT_DIR}/bpftrace_offcpu_sched_switch.stderr" || true
} >"${RESULT_DIR}/bpftrace_summary.txt"

log "bpftrace results: ${RESULT_DIR}"
