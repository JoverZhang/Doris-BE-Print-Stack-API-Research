#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
./stop.sh >/dev/null 2>&1 || true
rm -f stacktrace-ubuntu-24.04.qcow2 seed.iso user-data.generated vm.pid vm.log id_ed25519 id_ed25519.pub
echo "destroyed VM disk and seed"
