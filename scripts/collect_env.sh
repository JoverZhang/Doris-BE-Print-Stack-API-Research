#!/usr/bin/env bash
set -euo pipefail

mkdir -p outputs
{
  date -Is
  uname -a
  command -v qemu-system-x86_64 || true
  qemu-system-x86_64 --version 2>/dev/null | head -n 2 || true
  command -v just || true
  command -v git || true
  command -v curl || true
  command -v qemu-img || true
  test -e /dev/kvm && ls -l /dev/kvm || true
  nproc || true
  free -h || true
  df -h . || true
} | tee outputs/environment.txt

