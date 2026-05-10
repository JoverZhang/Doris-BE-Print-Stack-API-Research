#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$CASE_DIR"

VERSION="${CLICKHOUSE_VERSION:-26.3.10.62}"
CHANNEL_SUFFIX="${CLICKHOUSE_CHANNEL_SUFFIX:-lts}"
ARCH="${CLICKHOUSE_ARCH:-amd64}"
CACHE_DIR="${CLICKHOUSE_CACHE_DIR:-cache}"
ARCHIVE="clickhouse-common-static-${VERSION}-${ARCH}.tgz"
SHA512_FILE="${ARCHIVE}.sha512"
URL="https://github.com/ClickHouse/ClickHouse/releases/download/v${VERSION}-${CHANNEL_SUFFIX}/${ARCHIVE}"

mkdir -p "$CACHE_DIR" bin outputs

if [[ ! -f "${CACHE_DIR}/${SHA512_FILE}" ]]; then
  curl -L --fail --retry 3 --retry-delay 2 -o "${CACHE_DIR}/${SHA512_FILE}" "${URL}.sha512"
fi

if [[ ! -f "${CACHE_DIR}/${ARCHIVE}" ]]; then
  curl -L --fail --retry 3 --retry-delay 2 -o "${CACHE_DIR}/${ARCHIVE}" "$URL"
fi

(cd "$CACHE_DIR" && sha512sum -c "$SHA512_FILE")
sha256sum "${CACHE_DIR}/${ARCHIVE}" > outputs/clickhouse_package.sha256
stat -Lc 'clickhouse_package_size_bytes=%s' "${CACHE_DIR}/${ARCHIVE}" > outputs/clickhouse_package.size.txt
printf '%s\n' "$URL" > outputs/clickhouse_package.url.txt

if [[ ! -x bin/clickhouse ]]; then
  tar -xzf "${CACHE_DIR}/${ARCHIVE}" -C bin --strip-components=3 \
    "clickhouse-common-static-${VERSION}/usr/bin/clickhouse"
  chmod +x bin/clickhouse
fi

bin/clickhouse --version
