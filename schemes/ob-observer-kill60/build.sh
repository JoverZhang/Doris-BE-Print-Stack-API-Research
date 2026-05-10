#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCHEME_DIR"

TAG="${OCEANBASE_TAG:-v4.5.0_CE}"
COMMIT="${OCEANBASE_COMMIT:-0e8d5ad012baf0953b2032a35a88bdf8886e9a7a}"
SOURCE_DIR="${OCEANBASE_SOURCE_DIR:-$SCHEME_DIR/.cache/oceanbase-$TAG}"

mkdir -p commands .cache

if [[ ! -d "$SOURCE_DIR/.git" ]]; then
  git clone --depth 1 --branch "$TAG" --filter=blob:none \
    https://github.com/oceanbase/oceanbase.git "$SOURCE_DIR"
fi

actual_commit="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
if [[ "$actual_commit" != "$COMMIT" ]]; then
  echo "unexpected OceanBase commit: $actual_commit, expected $COMMIT" >&2
  exit 2
fi

if [[ "${OB_FULL_SOURCE_BUILD:-0}" != "1" ]]; then
  ./commands/source_build_probe.sh > commands/source_build_probe.out
  echo "BLOCKED: full observer source build is disabled by default. Set OB_FULL_SOURCE_BUILD=1 after provisioning deps." >&2
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
