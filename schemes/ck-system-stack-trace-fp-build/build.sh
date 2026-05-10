#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG="${CLICKHOUSE_TAG:-v26.3.10.62-lts}"
COMMIT="${CLICKHOUSE_COMMIT:-e1c11930c28196f954a93287e43c1aa112c8c607}"
SRC_DIR="${CLICKHOUSE_SRC_DIR:-$SCHEME_DIR/.cache/ClickHouse-$TAG}"
BUILD_DIR="${CLICKHOUSE_BUILD_DIR:-$SCHEME_DIR/build/fp}"
JOBS="${CLICKHOUSE_BUILD_JOBS:-$(nproc)}"
RUST_TOOLCHAIN="${CLICKHOUSE_RUST_TOOLCHAIN:-nightly-2025-07-07}"

if [[ "${CLICKHOUSE_ATTEMPT_SOURCE_BUILD:-0}" != "1" ]]; then
  "$SCHEME_DIR/commands/source_build_probe.sh" > "$SCHEME_DIR/commands/source_build_probe.out"
  cat "$SCHEME_DIR/commands/source_build_probe.out" >&2
  echo "BLOCKED: set CLICKHOUSE_ATTEMPT_SOURCE_BUILD=1 to retry the long source build explicitly." >&2
  exit 2
fi

if [[ ! -d "$SRC_DIR/.git" ]]; then
  mkdir -p "$(dirname "$SRC_DIR")"
  git clone --depth 1 --branch "$TAG" https://github.com/ClickHouse/ClickHouse.git "$SRC_DIR"
fi

actual_commit="$(git -C "$SRC_DIR" rev-parse HEAD)"
if [[ "$actual_commit" != "$COMMIT" ]]; then
  echo "ClickHouse source commit mismatch: expected $COMMIT, got $actual_commit" >&2
  exit 1
fi

git -C "$SRC_DIR" submodule update --init --recursive --depth 1 --jobs "${CLICKHOUSE_SUBMODULE_JOBS:-8}"

if ! command -v rustup >/dev/null 2>&1; then
  echo "Missing rustup; ClickHouse $TAG requires Rust toolchain $RUST_TOOLCHAIN." >&2
  exit 1
fi

if ! rustup toolchain list | awk '{print $1}' | grep -qx "${RUST_TOOLCHAIN}-x86_64-unknown-linux-gnu"; then
  echo "Missing Rust toolchain $RUST_TOOLCHAIN. Install with: rustup toolchain install $RUST_TOOLCHAIN" >&2
  exit 1
fi

cmake -S "$SRC_DIR" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_COMPILER="${CC:-clang}" \
  -DCMAKE_CXX_COMPILER="${CXX:-clang++}" \
  -DENABLE_TESTS=OFF \
  -DENABLE_CLICKHOUSE_ALL=OFF \
  -DENABLE_CLICKHOUSE_KEEPER=OFF \
  -DENABLE_CLICKHOUSE_KEEPER_CONVERTER=OFF \
  -DENABLE_CLICKHOUSE_KEEPER_CLIENT=OFF \
  -DENABLE_THINLTO=OFF \
  -DDISABLE_OMIT_FRAME_POINTER=ON

cmake --build "$BUILD_DIR" --target clickhouse --parallel "$JOBS"

test -x "$BUILD_DIR/programs/clickhouse"
echo "$BUILD_DIR/programs/clickhouse"
