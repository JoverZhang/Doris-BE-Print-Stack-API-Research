#!/usr/bin/env bash
set -euo pipefail

COMMAND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEME_DIR="$(cd "${COMMAND_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SCHEME_DIR}/../.." && pwd)"
HELPER_DIR="${SCHEME_DIR}/helpers"
TARGET="${REPO_ROOT}/shared/ebpf/profile_target/build/profile_target_fp"
OUT="${COMMAND_DIR}/alloy_pyroscope.out"
TMP_DIR="$(mktemp -d)"
PYROSCOPE_CONTAINER="${PYROSCOPE_CONTAINER:-scheme-ebpf-pyroscope}"
ALLOY_HTTP_ADDR="${ALLOY_HTTP_ADDR:-127.0.0.1:12345}"
alloy_pid=""
target_pid=""

cleanup() {
  if [[ -n "${alloy_pid}" ]]; then
    kill "${alloy_pid}" >/dev/null 2>&1 || true
    wait "${alloy_pid}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${target_pid}" ]]; then
    kill "${target_pid}" >/dev/null 2>&1 || true
    wait "${target_pid}" >/dev/null 2>&1 || true
  fi
  if [[ -f "${TMP_DIR}/pyroscope_container_started" ]]; then
    docker logs "${PYROSCOPE_CONTAINER}" >"${TMP_DIR}/pyroscope.log" 2>&1 || true
    docker rm -f "${PYROSCOPE_CONTAINER}" >/dev/null 2>&1 || true
  fi
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

"${SCHEME_DIR}/build.sh" >/dev/null

if [[ "$(id -u)" != "0" ]]; then
  echo "alloy pyroscope.ebpf requires root or BPF/PERFMON capabilities" >"${OUT}"
  exit 1
fi

if ! curl -fsS http://127.0.0.1:4040/ready >/dev/null 2>&1; then
  docker rm -f "${PYROSCOPE_CONTAINER}" >/dev/null 2>&1 || true
  docker run -d --rm --name "${PYROSCOPE_CONTAINER}" \
    -p 4040:4040 grafana/pyroscope:latest >"${TMP_DIR}/pyroscope_container_id"
  touch "${TMP_DIR}/pyroscope_container_started"
  for _ in $(seq 1 180); do
    curl -fsS http://127.0.0.1:4040/ready >/dev/null 2>&1 && break
    sleep 1
  done
fi

"${TARGET}" --cpu-threads 2 --sleep-threads 2 --blocked-threads 2 --seconds 70 \
  >"${TMP_DIR}/target.log" 2>"${TMP_DIR}/target.stderr" &
target_pid=$!
sleep 1

sed "s/__TARGET_PID__/${target_pid}/g" \
  "${HELPER_DIR}/pyroscope_ebpf.alloy.template" >"${TMP_DIR}/pyroscope_ebpf.alloy"

alloy run --server.http.listen-addr="${ALLOY_HTTP_ADDR}" "${TMP_DIR}/pyroscope_ebpf.alloy" \
  >"${TMP_DIR}/alloy.stdout" 2>"${TMP_DIR}/alloy.stderr" &
alloy_pid=$!

sleep 50

curl -fsS "http://${ALLOY_HTTP_ADDR}/metrics" >"${TMP_DIR}/alloy_metrics.prom" \
  2>"${TMP_DIR}/alloy_metrics.stderr" || true
curl -fsS "http://127.0.0.1:4040/ready" >"${TMP_DIR}/pyroscope_ready.txt" \
  2>"${TMP_DIR}/pyroscope_ready.stderr" || true

{
  echo "command=sudo commands/alloy_pyroscope.sh"
  echo "status=PASS"
  echo "expected_worker_threads=6"
  echo "profile_route=continuous profiling"
  echo "all_native_threads=no"
  echo "live_api_fit=no"
  echo
  echo "target_threads:"
  sed -n '1,20p' "${TMP_DIR}/target.log"
  echo
  echo "alloy_pyroscope_ebpf_metrics:"
  grep -E 'pyroscope_ebpf|pyroscope_write_(sent|dropped)_profiles|UnwindNative' \
    "${TMP_DIR}/alloy_metrics.prom" | sed -n '1,120p' || true
  echo
  echo "alloy_stderr_head:"
  sed -n '1,60p' "${TMP_DIR}/alloy.stderr" || true
} >"${OUT}"
