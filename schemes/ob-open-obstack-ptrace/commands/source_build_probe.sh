#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${OBSTACK_SOURCE_DIR:-$SCHEME_DIR/.cache/obstack-source}"

echo "command=source_build_probe"
echo "repo=https://github.com/oceanbase/obstack.git"
echo "release_tag=none-published"
echo "commit=d91edd6d882a33b69164f8d3e809092408da3a33"
echo "source_dir_present=$([[ -d "$SOURCE_DIR/.git" ]] && echo yes || echo no)"
if [[ -d "$SOURCE_DIR/.git" ]]; then
  echo "source_commit=$(git -C "$SOURCE_DIR" rev-parse HEAD)"
fi

echo
echo "host_probe:"
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  echo "os=${PRETTY_NAME:-unknown}"
  echo "id=${ID:-unknown}"
fi
echo "arch=$(uname -m)"
echo "cmake=$(command -v cmake || true)"
echo "observed_command=timeout 120 bash -lc 'cd .cache/obstack-source && ./build.sh release'"
echo "observed_status=BLOCKED"
echo "observed_error_1=deps/dep_create.sh reports: [ERROR] 'Arch Linux (x86_64)' is not supported yet."
echo "observed_error_2=build.sh then cannot find deps/usr/local/oceanbase/devtools/bin/cmake."

echo
echo "decision=BLOCKED: open-source obstack was not built from source in the current host environment."
