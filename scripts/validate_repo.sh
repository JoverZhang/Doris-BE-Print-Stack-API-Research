#!/usr/bin/env bash
set -euo pipefail

required=(
  README.md
  justfile
  repos.lock.yaml
  templates/case.yaml
  templates/report.md
  vm/ubuntu-24.04/create.sh
  vm/ubuntu-24.04/start.sh
  vm/ubuntu-24.04/ssh.sh
  vm/ubuntu-24.04/destroy.sh
)

for path in "${required[@]}"; do
  test -e "$path" || { echo "missing: $path" >&2; exit 1; }
done

echo "repo skeleton ok"

