#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${CASE_DIR}/build"
RESULT_DIR="${CASE_DIR}/results/latest"
TARGET_FP="${BUILD_DIR}/profile_target_fp"
TARGET_NOFP="${BUILD_DIR}/profile_target_nofp"

mkdir -p "${BUILD_DIR}" "${RESULT_DIR}"

log() {
  printf '[task20] %s\n' "$*" >&2
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    log "missing command: ${cmd}"
    return 1
  fi
}

is_root() {
  [[ "$(id -u)" == "0" ]]
}

write_env_snapshot() {
  {
    echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "uname=$(uname -a)"
    echo "uid=$(id -u)"
    echo "user=$(id -un 2>/dev/null || true)"
    echo "perf=$(perf --version 2>/dev/null || echo missing)"
    echo "bpftrace=$(bpftrace --version 2>/dev/null || echo missing)"
    echo "alloy=$(alloy --version 2>/dev/null | head -n 1 || echo missing)"
    echo "docker=$(docker --version 2>/dev/null || echo missing)"
    echo "perf_event_paranoid=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo unavailable)"
    echo "unprivileged_bpf_disabled=$(cat /proc/sys/kernel/unprivileged_bpf_disabled 2>/dev/null || echo unavailable)"
    echo "kptr_restrict=$(cat /proc/sys/kernel/kptr_restrict 2>/dev/null || echo unavailable)"
    echo "perf_event_max_stack=$(cat /proc/sys/kernel/perf_event_max_stack 2>/dev/null || echo unavailable)"
    echo "btf_vmlinux=$(test -r /sys/kernel/btf/vmlinux && echo readable || echo unavailable)"
    echo "tracefs=$(test -d /sys/kernel/tracing && echo present || echo unavailable)"
    echo "debugfs=$(test -d /sys/kernel/debug && echo present || echo unavailable)"
  } >"${RESULT_DIR}/environment.txt"
}

relax_kernel_settings_for_vm() {
  if ! is_root; then
    log "not root; skip sysctl relaxation"
    return 0
  fi
  sysctl -w kernel.perf_event_paranoid=-1 >/dev/null 2>&1 || true
  sysctl -w kernel.kptr_restrict=0 >/dev/null 2>&1 || true
}

postprocess_perf_data() {
  local data_file="$1"
  local prefix="$2"
  if [[ -s "${data_file}" ]]; then
    perf script -i "${data_file}" \
      >"${RESULT_DIR}/${prefix}.script" \
      2>"${RESULT_DIR}/${prefix}_script.stderr" || true
    perf report -i "${data_file}" --stdio --no-children \
      --sort comm,dso,symbol,srcline \
      >"${RESULT_DIR}/${prefix}.report" \
      2>"${RESULT_DIR}/${prefix}_report.stderr" || true
  fi
}

summarize_perf_script() {
  local script_file="$1"
  local out_file="$2"
  {
    echo "script=${script_file}"
    if [[ -s "${script_file}" ]]; then
      echo "sample_count=$(grep -c 'cpu-clock:u' "${script_file}" || true)"
      echo "unique_tids=$(grep -E '^profile_target_' "${script_file}" | awk '{print $2}' | sort -u | paste -sd ',' -)"
      echo "unique_tid_count=$(grep -E '^profile_target_' "${script_file}" | awk '{print $2}' | sort -u | wc -l)"
      echo "first_sample:"
      sed -n '1,35p' "${script_file}"
    else
      echo "missing_or_empty=true"
    fi
  } >"${out_file}"
}
