#!/usr/bin/env bash
# Reason: host entrypoint for the PR 22549 reproducer. The actual work must
# run in the Doris build container so it uses the same toolchain as phase2.
# Local: reproduce/pr22549-jemalloc-dl-iterate-phdr.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../.." && pwd)"

cd "$project_root"
exec ./scripts/in-container "${script_dir}/run-in-container.sh" "$@"
