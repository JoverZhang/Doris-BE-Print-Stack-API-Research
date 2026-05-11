#!/usr/bin/env bash
set -euo pipefail

required=(
  .gitmodules
  .clangd
  .vscode/launch.json
  .vscode/settings.json
  .vscode/tasks.json
  CMakeLists.txt
  CMakePresets.json
  README.md
  justfile
  repos.lock
  scripts/validate_repo.sh
  scripts/validate_repos.sh
  scripts/sync_repos.sh
  vm/ubuntu-24.04/create.sh
  vm/ubuntu-24.04/start.sh
  vm/ubuntu-24.04/start_bg.sh
  vm/ubuntu-24.04/ssh.sh
  vm/ubuntu-24.04/destroy.sh
)

schemes=(
  ck-system-stack-trace
  ob-observer-kill60
  ob-ocp-obstack
  ob-open-obstack-ptrace
  ebpf-perf-bpftrace
  ebpf-alloy-pyroscope
)

for path in "${required[@]}"; do
  test -e "$path" || { echo "missing: $path" >&2; exit 1; }
done

./scripts/validate_repos.sh

for forbidden in case.yaml matrix.csv templates reference_checklist REPORT.md; do
  if [[ -e "$forbidden" ]]; then
    echo "forbidden old-contract path exists: $forbidden" >&2
    exit 1
  fi
done

for scheme in "${schemes[@]}"; do
  base="schemes/$scheme"
  test -f "$base/README.md" || { echo "missing scheme README: $base" >&2; exit 1; }
  test -x "$base/build.sh" || { echo "missing executable build.sh: $base" >&2; exit 1; }
  test -x "$base/run.sh" || { echo "missing executable run.sh: $base" >&2; exit 1; }
  test -f "$base/minimal_impl/README.md" || { echo "missing minimal_impl README: $base" >&2; exit 1; }
  grep -q '^## Source Trace' "$base/README.md" || { echo "missing Source Trace section: $base/README.md" >&2; exit 1; }
done

if git ls-files | grep -E '(^|/)outputs/|case\.yaml$|matrix\.csv$|^templates/|^reference_checklist/|release-binary|clickhouse-common-static' >/dev/null; then
  echo "tracked old-contract output or release-binary evidence remains" >&2
  git ls-files | grep -E '(^|/)outputs/|case\.yaml$|matrix\.csv$|^templates/|^reference_checklist/|release-binary|clickhouse-common-static' >&2
  exit 1
fi

echo "new contract skeleton ok"
