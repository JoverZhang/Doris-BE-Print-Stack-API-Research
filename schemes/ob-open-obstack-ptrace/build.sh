#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCHEME_DIR"

COMMIT="${OBSTACK_COMMIT:-d91edd6d882a33b69164f8d3e809092408da3a33}"
REPO_ROOT="$(git -C "$SCHEME_DIR" rev-parse --show-toplevel)"
SOURCE_DIR="${OBSTACK_SOURCE_DIR:-$REPO_ROOT/repos/source/obstack-master}"
JOBS="${OBSTACK_BUILD_JOBS:-4}"

mkdir -p .cache

if [[ ! -d "$SOURCE_DIR/.git" ]]; then
  echo "BLOCKED: obstack source submodule is unavailable at $SOURCE_DIR. Run just repos-sync." >&2
  exit 2
fi

actual_commit="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
if [[ "$actual_commit" != "$COMMIT" ]]; then
  echo "unexpected obstack commit: $actual_commit, expected $COMMIT" >&2
  exit 2
fi

for candidate in "$SOURCE_DIR"/build_release/src/obstack "$SOURCE_DIR"/build*/src/obstack; do
  if [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    exit 0
  fi
done

build_with_host() {
  (
    cd "$SOURCE_DIR"
    ./build.sh release
    make -C build_release -j"$JOBS" CXX_DEFINES="-DREVISION=\\\"$COMMIT\\\""
  )
}

build_with_podman() {
  case "$SOURCE_DIR" in
    "$REPO_ROOT"/*) ;;
    *)
      echo "podman build requires OBSTACK_SOURCE_DIR under repo root: $REPO_ROOT" >&2
      exit 2
      ;;
  esac

  local source_rel="${SOURCE_DIR#"$REPO_ROOT"/}"
  local image="${OBSTACK_PODMAN_IMAGE:-docker.io/library/centos:7}"

  podman run --rm --security-opt label=disable \
    -v "$REPO_ROOT:/work" -w /work \
    -e "SOURCE_DIR=/work/$source_rel" \
    -e "OBSTACK_COMMIT=$COMMIT" \
    -e "OBSTACK_BUILD_JOBS=$JOBS" \
    "$image" bash -lc '
set -euo pipefail
sed -i s/mirror.centos.org/vault.centos.org/g /etc/yum.repos.d/CentOS-*.repo
sed -i s/^#.*baseurl=http/baseurl=http/g /etc/yum.repos.d/CentOS-*.repo
sed -i s/^mirrorlist=http/#mirrorlist=http/g /etc/yum.repos.d/CentOS-*.repo
yum install -y wget rpm-build rpmdevtools cpio make gcc gcc-c++ glibc-devel libstdc++-devel zlib-devel ncurses-devel file git which tar gzip bzip2 xz >/tmp/obstack-yum.log 2>&1
git config --global --add safe.directory "$SOURCE_DIR"
cd "$SOURCE_DIR"
./build.sh release
make -C build_release -j"$OBSTACK_BUILD_JOBS" CXX_DEFINES="-DREVISION=\\\"$OBSTACK_COMMIT\\\""
'
}

case "${OBSTACK_BUILD_MODE:-podman-centos7}" in
  host)
    build_with_host
    ;;
  podman-centos7)
    command -v podman >/dev/null 2>&1 || { echo "podman is required for OBSTACK_BUILD_MODE=podman-centos7" >&2; exit 2; }
    build_with_podman
    ;;
  *)
    echo "unknown OBSTACK_BUILD_MODE=${OBSTACK_BUILD_MODE}" >&2
    exit 2
    ;;
esac

for candidate in "$SOURCE_DIR"/build_release/src/obstack "$SOURCE_DIR"/build*/src/obstack; do
  if [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    exit 0
  fi
done

echo "built obstack binary was not found under $SOURCE_DIR/build*/src/obstack" >&2
exit 2
