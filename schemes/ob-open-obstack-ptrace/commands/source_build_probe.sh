#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(git -C "$SCHEME_DIR" rev-parse --show-toplevel)"
SOURCE_DIR="${OBSTACK_SOURCE_DIR:-$REPO_ROOT/repos/source/obstack-master}"
COMMIT="${OBSTACK_COMMIT:-d91edd6d882a33b69164f8d3e809092408da3a33}"
CACHE_DIR="$SCHEME_DIR/.cache"
raw="$CACHE_DIR/open_obstack_source_build.raw"

mkdir -p "$CACHE_DIR"

echo "command=source_build_probe"
echo "repo=https://github.com/oceanbase/obstack.git"
echo "release_tag=none-published"
echo "commit=$COMMIT"
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
echo "observed_command=timeout 120 bash -lc 'cd repos/source/obstack-master && ./build.sh release'"
echo "observed_status=BLOCKED_ON_HOST"
echo "observed_error_1=deps/dep_create.sh reports unsupported host on Arch Linux."
echo "observed_error_2=build.sh then cannot find deps/usr/local/oceanbase/devtools/bin/cmake."

echo
echo "podman_source_build:"
echo "image=${OBSTACK_PODMAN_IMAGE:-docker.io/library/centos:7}"
echo "command=OBSTACK_BUILD_MODE=podman-centos7 OBSTACK_SOURCE_DIR=$SOURCE_DIR $SCHEME_DIR/build.sh"
echo "revision_workaround=make CXX_DEFINES=-DREVISION=\\\"$COMMIT\\\""
echo "revision_workaround_reason=upstream CMake executes git log from the build directory, leaving REVISION empty under this mounted build."

set +e
OBSTACK_BUILD_MODE=podman-centos7 OBSTACK_SOURCE_DIR="$SOURCE_DIR" "$SCHEME_DIR/build.sh" >"$raw" 2>&1
rc=$?
set -e

echo "exit_code=$rc"
if [[ "$rc" -ne 0 ]]; then
  echo "status=FAIL"
  echo
  echo "build_log_tail:"
  tail -n 120 "$raw"
  exit "$rc"
fi

bin="$(tail -n 1 "$raw")"
echo "binary_path_host=$bin"
echo "binary_exists=$([[ -x "$bin" ]] && echo yes || echo no)"
if [[ ! -x "$bin" ]]; then
  echo "status=FAIL"
  echo "reason=build command exited 0 but final line is not an executable obstack binary"
  exit 2
fi

echo "binary_size_bytes=$(stat -c '%s' "$bin")"
echo "binary_file=$(file -b "$bin")"
build_id="$(file -b "$bin" | sed -n 's/.*BuildID\[sha1\]=\([^,]*\).*/\1/p')"
echo "binary_build_id=${build_id:-unknown}"
echo "version_output=not_run_on_host; runtime is verified by attach_synthetic.out and attach_observer.out"
echo "status=PASS"
echo
echo "decision=PASS: open-source obstack was built from source under podman CentOS 7; no release binary evidence is used."
