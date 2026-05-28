#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

disk="stacktrace-ubuntu-24.04.qcow2"
seed="seed.iso"
mem="${VM_MEM:-8192}"
cpus="${VM_CPUS:-4}"
ssh_port="${VM_SSH_PORT:-2222}"
daemonize="${VM_DAEMONIZE:-0}"
pidfile="${VM_PIDFILE:-vm.pid}"
logfile="${VM_LOGFILE:-vm.log}"

test -f "$disk" || { echo "missing $disk; run just vm-create" >&2; exit 1; }
test -f "$seed" || { echo "missing $seed; run just vm-create" >&2; exit 1; }

args=(
  -enable-kvm \
  -machine q35 \
  -cpu host \
  -smp "$cpus" \
  -m "$mem" \
  -drive "file=$disk,if=virtio,format=qcow2" \
  -drive "file=$seed,if=virtio,format=raw,readonly=on" \
  -netdev "user,id=net0,hostfwd=tcp::${ssh_port}-:22" \
  -device virtio-net-pci,netdev=net0
)

if [[ "$daemonize" == "1" ]]; then
  exec qemu-system-x86_64 \
    "${args[@]}" \
    -display none \
    -serial "file:${logfile}" \
    -daemonize \
    -pidfile "$pidfile"
fi

exec qemu-system-x86_64 "${args[@]}" -nographic
