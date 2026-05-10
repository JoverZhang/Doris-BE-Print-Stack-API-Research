#!/usr/bin/env bash
set -euo pipefail

required=(
  README.md
  justfile
  repos.lock.yaml
  matrix.csv
  templates/case.yaml
  templates/report.md
  reference_checklist/checklist.md
  vm/ubuntu-24.04/create.sh
  vm/ubuntu-24.04/start.sh
  vm/ubuntu-24.04/start_bg.sh
  vm/ubuntu-24.04/wait_ssh.sh
  vm/ubuntu-24.04/ssh.sh
  vm/ubuntu-24.04/stop.sh
  vm/ubuntu-24.04/destroy.sh
)

for path in "${required[@]}"; do
  test -e "$path" || { echo "missing: $path" >&2; exit 1; }
done

while IFS= read -r case_file; do
  grep -Eq '^status: (PASS|PARTIAL|FAIL|BLOCKED|todo|in_progress|in_review|done)' "$case_file" || {
    echo "case missing status: $case_file" >&2
    exit 1
  }
done < <(find . -path './.git' -prune -o -name case.yaml -print)

echo "repo skeleton ok"
