#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${OCEANBASE_SOURCE_DIR:-$SCHEME_DIR/.cache/oceanbase-v4.5.0_CE}"

echo "command=source_build_probe"
echo "release_tag=v4.5.0_CE"
echo "commit=0e8d5ad012baf0953b2032a35a88bdf8886e9a7a"
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
    echo "observed_command=timeout 120 bash -lc 'cd .cache/oceanbase-v4.5.0_CE && ./build.sh release --init --make -j4'"
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
  echo "observed_status=BLOCKED"
  echo "observed_error=open /usr/bin/chage: operation not permitted while applying almalinux:8 layer in rootless podman"
  echo "rerun_hint=PODMAN_PROBE_PULL=1 $0"
  if [[ "${PODMAN_PROBE_PULL:-0}" == "1" ]]; then
    podman run --rm docker.io/library/almalinux:8 cat /etc/os-release
  fi
else
  echo "podman_status=BLOCKED"
  echo "podman_blocker=podman is not installed"
fi

echo
echo "decision=BLOCKED: real observer source build was not completed in the current environment."
