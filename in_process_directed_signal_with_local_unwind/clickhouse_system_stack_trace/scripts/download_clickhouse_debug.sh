#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$CASE_DIR"

VERSION="${CLICKHOUSE_VERSION:-26.3.10.62}"
CHANNEL_SUFFIX="${CLICKHOUSE_CHANNEL_SUFFIX:-lts}"
ARCH="${CLICKHOUSE_ARCH:-amd64}"
CACHE_DIR="${CLICKHOUSE_CACHE_DIR:-cache}"
DEBUG_ARCHIVE="clickhouse-common-static-dbg-${VERSION}-${ARCH}.tgz"
DEBUG_SHA512="${DEBUG_ARCHIVE}.sha512"
DEBUG_URL="https://github.com/ClickHouse/ClickHouse/releases/download/v${VERSION}-${CHANNEL_SUFFIX}/${DEBUG_ARCHIVE}"
DEBUG_MEMBER="clickhouse-common-static-dbg-${VERSION}/usr/lib/debug/usr/bin/clickhouse.debug"
DEBUG_EXTRACT_DIR="${CACHE_DIR}/debug-extract"
DEBUG_BINARY="${DEBUG_EXTRACT_DIR}/${DEBUG_MEMBER}"

mkdir -p "$CACHE_DIR" "$DEBUG_EXTRACT_DIR" bin outputs

if [[ ! -f "${CACHE_DIR}/${DEBUG_SHA512}" ]]; then
  curl -L --fail --retry 3 --retry-delay 2 -o "${CACHE_DIR}/${DEBUG_SHA512}" "${DEBUG_URL}.sha512"
fi

if [[ ! -f "${CACHE_DIR}/${DEBUG_ARCHIVE}" ]]; then
  curl -L --fail --retry 3 --retry-delay 2 -o "${CACHE_DIR}/${DEBUG_ARCHIVE}" "$DEBUG_URL"
fi

(cd "$CACHE_DIR" && sha512sum -c "$DEBUG_SHA512")
sha256sum "${CACHE_DIR}/${DEBUG_ARCHIVE}" > outputs/debug_package.sha256
sha512sum "${CACHE_DIR}/${DEBUG_ARCHIVE}" > outputs/debug_package.local.sha512
stat -Lc 'debug_package_size_bytes=%s' "${CACHE_DIR}/${DEBUG_ARCHIVE}" > outputs/debug_package.size.txt
printf '%s\n' "$DEBUG_URL" > outputs/debug_package.url.txt
tar -tzf "${CACHE_DIR}/${DEBUG_ARCHIVE}" | sed -n '1,120p' > outputs/debug_package_listing_head.txt

if [[ ! -s "$DEBUG_BINARY" ]]; then
  tar -xzf "${CACHE_DIR}/${DEBUG_ARCHIVE}" -C "$DEBUG_EXTRACT_DIR" "$DEBUG_MEMBER"
fi

ln -sfn "../${DEBUG_BINARY}" bin/clickhouse.debug

{
  echo "debug_url=${DEBUG_URL}"
  echo "debug_archive=${CACHE_DIR}/${DEBUG_ARCHIVE}"
  cat outputs/debug_package.size.txt
  echo "debug_member=${DEBUG_MEMBER}"
  echo "debug_binary=${DEBUG_BINARY}"
  echo "case_local_debug_symlink=bin/clickhouse.debug"
  echo "global_debug_layout_if_needed=/usr/lib/debug/usr/bin/clickhouse.debug or /usr/lib/debug/.build-id/<build-id>.debug"
} > outputs/debug_info_layout.txt

readelf -n bin/clickhouse 2>&1 | grep -A1 'Build ID' > outputs/clickhouse_build_id.txt || true
readelf -n bin/clickhouse.debug 2>&1 | grep -A1 'Build ID' > outputs/clickhouse_debug_build_id.txt || true

echo "Debug info ready at bin/clickhouse.debug"
