#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VM_REPO="${STACKTRACE_VM_REPO:-/home/repro/stacktrace-research-repro}"
VM_SSH="${STACKTRACE_VM_SSH:-${REPO_ROOT}/vm/ubuntu-24.04/ssh.sh}"

if [[ "${STACKTRACE_SCHEME_IN_VM:-0}" != "1" ]]; then
  if [[ ! -x "${VM_SSH}" ]]; then
    echo "VM SSH helper not executable: ${VM_SSH}" >&2
    echo "Set STACKTRACE_VM_SSH=/path/to/vm/ubuntu-24.04/ssh.sh or run inside the VM with STACKTRACE_SCHEME_IN_VM=1." >&2
    exit 2
  fi

  tar -C "${REPO_ROOT}" -czf - schemes/ebpf-perf-bpftrace shared/ebpf/profile_target |
    "${VM_SSH}" "mkdir -p '${VM_REPO}' && tar -C '${VM_REPO}' -xzf -"

  "${VM_SSH}" "cd '${VM_REPO}' && STACKTRACE_SCHEME_IN_VM=1 schemes/ebpf-perf-bpftrace/run.sh"

  "${VM_SSH}" "cd '${VM_REPO}' && tar -czf - schemes/ebpf-perf-bpftrace/commands/*.out schemes/ebpf-perf-bpftrace/minimal_impl/profile_target.out" |
    tar -C "${REPO_ROOT}" -xzf -
  exit 0
fi

"${SCRIPT_DIR}/build.sh" >/dev/null
"${SCRIPT_DIR}/minimal_impl/run.sh" >/dev/null
"${SCRIPT_DIR}/commands/perf_fp.sh"
"${SCRIPT_DIR}/commands/perf_dwarf.sh"
"${SCRIPT_DIR}/commands/run_bpftrace_ustack.sh"
"${SCRIPT_DIR}/commands/run_bpftrace_offcpu.sh"
