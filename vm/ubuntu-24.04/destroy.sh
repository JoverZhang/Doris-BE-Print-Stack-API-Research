#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
rm -f stacktrace-ubuntu-24.04.qcow2 seed.iso
echo "destroyed VM disk and seed"

