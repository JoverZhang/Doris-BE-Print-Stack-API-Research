#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_cmd alloy
require_cmd curl

if [[ ! -x "${TARGET_FP}" ]]; then
  "${SCRIPT_DIR}/build_target.sh"
fi

relax_kernel_settings_for_vm
write_env_snapshot

if ! is_root; then
  log "Alloy pyroscope.ebpf must run as root or with BPF/PERFMON-related capabilities"
  exit 1
fi

PYROSCOPE_CONTAINER="${PYROSCOPE_CONTAINER:-task20-pyroscope}"
ALLOY_HTTP_ADDR="${ALLOY_HTTP_ADDR:-127.0.0.1:12345}"
ALLOY_CONFIG="${RESULT_DIR}/pyroscope_ebpf.alloy"

start_pyroscope() {
  if curl -fsS http://127.0.0.1:4040/ready >/dev/null 2>&1; then
    log "Pyroscope already listening on 127.0.0.1:4040"
    echo "external" >"${RESULT_DIR}/pyroscope_container_mode.txt"
    return 0
  fi

  require_cmd docker
  docker rm -f "${PYROSCOPE_CONTAINER}" >/dev/null 2>&1 || true
  docker run -d --rm --name "${PYROSCOPE_CONTAINER}" \
    -p 4040:4040 grafana/pyroscope:latest \
    >"${RESULT_DIR}/pyroscope_container_id.txt"
  echo "docker" >"${RESULT_DIR}/pyroscope_container_mode.txt"

  for _ in $(seq 1 180); do
    if curl -fsS http://127.0.0.1:4040/ready >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  log "Pyroscope did not become ready"
  docker logs "${PYROSCOPE_CONTAINER}" >"${RESULT_DIR}/pyroscope.log" 2>&1 || true
  return 1
}

cleanup() {
  if [[ -n "${alloy_pid:-}" ]]; then
    kill "${alloy_pid}" >/dev/null 2>&1 || true
    wait "${alloy_pid}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${target_pid:-}" ]]; then
    kill "${target_pid}" >/dev/null 2>&1 || true
    wait "${target_pid}" >/dev/null 2>&1 || true
  fi
  if [[ -f "${RESULT_DIR}/pyroscope_container_mode.txt" ]] &&
     grep -qx docker "${RESULT_DIR}/pyroscope_container_mode.txt"; then
    docker logs "${PYROSCOPE_CONTAINER}" >"${RESULT_DIR}/pyroscope.log" 2>&1 || true
    docker rm -f "${PYROSCOPE_CONTAINER}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

start_pyroscope

"${TARGET_FP}" --cpu-threads 2 --sleep-threads 2 --blocked-threads 2 --seconds 75 \
  >"${RESULT_DIR}/target_alloy.log" 2>"${RESULT_DIR}/target_alloy.stderr" &
target_pid=$!
sleep 1

sed "s/__TARGET_PID__/${target_pid}/g" \
  "${CASE_DIR}/alloy/pyroscope_ebpf.alloy.template" >"${ALLOY_CONFIG}"

log "running Alloy pyroscope.ebpf for pid=${target_pid}"
alloy run --server.http.listen-addr="${ALLOY_HTTP_ADDR}" "${ALLOY_CONFIG}" \
  >"${RESULT_DIR}/alloy.stdout" 2>"${RESULT_DIR}/alloy.stderr" &
alloy_pid=$!

sleep 50

curl -fsS "http://${ALLOY_HTTP_ADDR}/metrics" \
  >"${RESULT_DIR}/alloy_metrics.prom" 2>"${RESULT_DIR}/alloy_metrics.stderr" || true
curl -fsS "http://127.0.0.1:4040/ready" \
  >"${RESULT_DIR}/pyroscope_ready.txt" 2>"${RESULT_DIR}/pyroscope_ready.stderr" || true

{
  echo "target_pid=${target_pid}"
  echo "alloy_pid=${alloy_pid}"
  echo "alloy_config=${ALLOY_CONFIG}"
  echo "target_threads:"
  sed -n '1,60p' "${RESULT_DIR}/target_alloy.log" || true
  echo
  echo "alloy_pyroscope_ebpf_metrics:"
  grep -E 'pyroscope_ebpf|pyroscope_write_(sent|dropped)_profiles|UnwindNative' \
    "${RESULT_DIR}/alloy_metrics.prom" | sed -n '1,120p' || true
  echo
  echo "alloy_stderr_head:"
  sed -n '1,80p' "${RESULT_DIR}/alloy.stderr" || true
} >"${RESULT_DIR}/industry_profiler_summary.txt"

log "industry profiler results: ${RESULT_DIR}"
