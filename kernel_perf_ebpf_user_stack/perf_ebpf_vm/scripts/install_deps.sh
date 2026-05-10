#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

export DEBIAN_FRONTEND=noninteractive

if ! is_root; then
  log "install_deps.sh must run as root inside the VM"
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  log "only apt-based Ubuntu/Debian guests are supported by this script"
  exit 1
fi

apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl wget gpg jq make g++ clang llvm elfutils \
  linux-tools-common linux-tools-generic bpftrace docker.io

apt-get install -y --no-install-recommends "linux-tools-$(uname -r)" || true

install -d -m 0755 /etc/apt/keyrings
if [[ ! -s /etc/apt/keyrings/grafana.asc ]]; then
  wget -q -O /etc/apt/keyrings/grafana.asc https://apt.grafana.com/gpg-full.key
fi
cat >/etc/apt/sources.list.d/grafana.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main
EOF
apt-get update
apt-get install -y --no-install-recommends alloy

systemctl enable --now docker >/dev/null 2>&1 || service docker start >/dev/null 2>&1 || true

relax_kernel_settings_for_vm
write_env_snapshot

log "dependencies installed; environment snapshot: ${RESULT_DIR}/environment.txt"
