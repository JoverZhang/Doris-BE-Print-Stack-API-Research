#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

image_url="${IMAGE_URL:-https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img}"
base="ubuntu-24.04-server-cloudimg-amd64.img"
disk="stacktrace-ubuntu-24.04.qcow2"
seed="seed.iso"
key="id_ed25519"
generated_user_data="user-data.generated"

if [[ ! -f "$base" ]]; then
  curl -L "$image_url" -o "$base"
fi

if [[ ! -f "$disk" ]]; then
  qemu-img create -f qcow2 -F qcow2 -b "$base" "$disk" 80G
fi

if [[ ! -f "$key" ]]; then
  ssh-keygen -t ed25519 -N "" -f "$key" -C stacktrace-repro-vm >/dev/null
fi
chmod 600 "$key"
chmod 644 "${key}.pub"

pubkey="$(cat "${key}.pub")"
cat >"$generated_user_data" <<EOF
#cloud-config
users:
  - name: repro
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - ${pubkey}
ssh_pwauth: false
write_files:
  - path: /etc/sysctl.d/99-stacktrace-repro.conf
    permissions: "0644"
    content: |
      kernel.perf_event_paranoid=-1
      kernel.kptr_restrict=0
package_update: true
packages:
  - build-essential
  - git
  - curl
  - ca-certificates
  - linux-tools-generic
  - linux-tools-common
  - bpftrace
  - clang
  - llvm
  - elfutils
  - jq
  - just
runcmd:
  - sysctl --system
EOF

xorriso -as mkisofs \
  -output "$seed" \
  -volid cidata \
  -joliet \
  -rock \
  -graft-points \
  user-data="$generated_user_data" \
  meta-data=meta-data \
  >/dev/null

echo "created $disk and $seed"
