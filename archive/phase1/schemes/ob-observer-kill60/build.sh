#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCHEME_DIR" rev-parse --show-toplevel)"
cd "$SCHEME_DIR"

TAG="${OCEANBASE_TAG:-v4.5.0_CE}"
COMMIT="${OCEANBASE_COMMIT:-0e8d5ad012baf0953b2032a35a88bdf8886e9a7a}"
SOURCE_DIR="${OCEANBASE_SOURCE_DIR:-$REPO_ROOT/repos/source/oceanbase-$TAG}"

mkdir -p .cache

for observer_bin in \
  "$SOURCE_DIR/build_release/src/observer/observer" \
  "$SOURCE_DIR/build_release/src/observer/observer/observer"
do
  if [[ -x "$observer_bin" ]]; then
    printf '%s\n' "$observer_bin"
    exit 0
  fi
done

if [[ ! -d "$SOURCE_DIR/.git" ]]; then
  echo "BLOCKED: OceanBase source submodule is unavailable at $SOURCE_DIR. Run just repos-sync." >&2
  exit 2
fi

actual_commit="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
if [[ "$actual_commit" != "$COMMIT" ]]; then
  echo "unexpected OceanBase commit: $actual_commit, expected $COMMIT" >&2
  exit 2
fi

if [[ "${OB_FULL_SOURCE_BUILD:-0}" != "1" ]]; then
  echo "BLOCKED: source-built observer binary is missing. Set OB_FULL_SOURCE_BUILD=1 after provisioning deps." >&2
  exit 2
fi

(
  cd "$SOURCE_DIR"
  ./build.sh release --init --make -j"${OB_BUILD_JOBS:-4}"
)

observer_bin="$SOURCE_DIR/build_release/src/observer/observer"
test -x "$observer_bin" || observer_bin="$SOURCE_DIR/build_release/src/observer/observer/observer"
test -x "$observer_bin"
printf '%s\n' "$observer_bin"
