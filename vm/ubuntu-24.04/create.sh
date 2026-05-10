#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

image_url="${IMAGE_URL:-https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img}"
base="ubuntu-24.04-server-cloudimg-amd64.img"
disk="stacktrace-ubuntu-24.04.qcow2"
seed="seed.iso"

if [[ ! -f "$base" ]]; then
  curl -L "$image_url" -o "$base"
fi

if [[ ! -f "$disk" ]]; then
  qemu-img create -f qcow2 -F qcow2 -b "$base" "$disk" 80G
fi

xorriso -as mkisofs -output "$seed" -volid cidata -joliet -rock user-data meta-data >/dev/null

echo "created $disk and $seed"

