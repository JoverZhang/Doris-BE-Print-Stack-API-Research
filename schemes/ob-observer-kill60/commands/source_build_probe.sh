#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(git -C "$SCHEME_DIR" rev-parse --show-toplevel)"
SOURCE_DIR="${OCEANBASE_SOURCE_DIR:-$REPO_ROOT/repos/source/oceanbase-v4.5.0_CE}"
SOURCE_DISPLAY="${SOURCE_DIR#"$REPO_ROOT"/}"

echo "command=source_build_probe"
echo "release_tag=v4.5.0_CE"
echo "commit=0e8d5ad012baf0953b2032a35a88bdf8886e9a7a"
echo "source_dir=$SOURCE_DISPLAY"
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
echo "rpmextract=$(command -v rpmextract.sh || true)"
echo "rpm2cpio=$(command -v rpm2cpio || true)"
echo "cpio=$(command -v cpio || true)"
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  if [[ "${ID:-}" == "arch" ]] && ! command -v rpmextract.sh >/dev/null 2>&1; then
    echo "observed_command=timeout 120 bash -lc 'cd repos/source/oceanbase-v4.5.0_CE && ./build.sh release --init --make -j4'"
    echo "host_status=BLOCKED"
    echo "host_blocker=OceanBase deps/init/dep_create.sh maps Arch to el8 but calls rpmextract.sh; rpmextract.sh is not installed."
    echo "observed_error=dep_create.sh: line 317: rpmextract.sh: command not found"
  else
    echo "host_status=UNKNOWN_OR_READY"
  fi
fi

echo
echo "podman_probe:"
echo "podman=$(command -v podman || true)"
if command -v podman >/dev/null 2>&1; then
  podman --version
  echo "observed_command=podman run --rm docker.io/library/almalinux:8 cat /etc/os-release"
  echo "observed_status=AVAILABLE_AFTER_USER_PULL"
  echo "rerun_hint=PODMAN_PROBE_PULL=1 $0"
  if [[ "${PODMAN_PROBE_PULL:-0}" == "1" ]]; then
    podman run --rm docker.io/library/almalinux:8 cat /etc/os-release
  fi
else
  echo "podman_status=BLOCKED"
  echo "podman_blocker=podman is not installed"
fi

echo
echo "decision=SOURCE_BUILD_PASS_IF observer binary exists under repos/source/oceanbase-v4.5.0_CE/build_release/src/observer/observer; otherwise rerun with OB_FULL_SOURCE_BUILD=1 after provisioning podman deps."
