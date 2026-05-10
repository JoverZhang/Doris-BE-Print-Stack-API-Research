#!/usr/bin/env bash
set -euo pipefail

bin="${1:?usage: clickhouse_metadata.sh /path/to/clickhouse}"

echo "binary=$bin"
"$bin" --version
readelf -n "$bin" 2>&1 | grep -A1 'Build ID' || true
