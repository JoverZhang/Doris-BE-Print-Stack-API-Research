#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

jobs="${REPOS_SUBMODULE_JOBS:-8}"
depth_arg=()
if [[ -n "${REPOS_SUBMODULE_DEPTH:-}" ]]; then
  depth_arg=(--depth "$REPOS_SUBMODULE_DEPTH")
fi

git submodule sync --recursive
git submodule update --init --recursive --jobs "$jobs" "${depth_arg[@]}" -- \
  repos/source/ClickHouse-v26.3.10.62-lts \
  repos/source/oceanbase-v4.5.0_CE \
  repos/source/obstack-master

./scripts/validate_repos.sh
