#!/usr/bin/env bash
set -euo pipefail

VARIANT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEME_DIR="$(cd "$VARIANT_DIR/../.." && pwd)"
cd "$VARIANT_DIR"

CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-}"
if [[ -z "$CLICKHOUSE_BIN" ]]; then
  if ! CLICKHOUSE_BIN="$(./build.sh | tail -n 1)"; then
    cat > queries/thread_stack.out <<'EOF'
BLOCKED: source-built ClickHouse frame-pointer binary was not produced. See ../commands/source_build_probe.out.
EOF
    cat > queries/thread_stack_fileline.out <<'EOF'
BLOCKED: source-built ClickHouse frame-pointer binary was not produced. See ../commands/source_build_probe.out.
EOF
    ./minimal_impl/run.sh
    echo "BLOCKED: source-built ClickHouse frame-pointer binary was not produced. Minimal impl output was refreshed." >&2
    exit 2
  fi
fi

test -x "$CLICKHOUSE_BIN"
mkdir -p tmp

normalize_output() {
  local output="$1"
  sed -i -E \
    -e "s#${SCHEME_DIR}#<scheme>#g" \
    -e "s#${VARIANT_DIR}#<scheme>/variants/fp-build#g" \
    -e 's#[^[:space:]]*/\.slock/agents/[A-Za-z0-9-]+/projects/stacktrace-research-repro[^[:space:]]*/schemes/ck-system-stack-trace#<scheme>#g' \
    -e 's/[[:space:]]+$//' \
    "$output"
}

run_query() {
  local input="$1"
  local output="${input%.sql}.out"
  "$CLICKHOUSE_BIN" local \
    --path "$SCHEME_DIR/tmp/local-${input##*/}" \
    --allow_introspection_functions=1 \
    --query "$(cat "$input")" > "$output"
  normalize_output "$output"
}

run_query queries/thread_stack.sql
run_query queries/thread_stack_fileline.sql

./commands/clickhouse_metadata.sh "$CLICKHOUSE_BIN" > commands/clickhouse_metadata.out
normalize_output commands/clickhouse_metadata.out

"$SCHEME_DIR/minimal_impl/fp-build/run.sh"

echo "wrote ClickHouse frame-pointer source-build outputs under $VARIANT_DIR"
