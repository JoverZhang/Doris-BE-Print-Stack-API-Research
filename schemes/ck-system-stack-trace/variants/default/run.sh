#!/usr/bin/env bash
set -euo pipefail

VARIANT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEME_DIR="$(cd "$VARIANT_DIR/../.." && pwd)"
REPO_ROOT="$(git -C "$VARIANT_DIR" rev-parse --show-toplevel)"
cd "$VARIANT_DIR"

CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-}"
if [[ -z "$CLICKHOUSE_BIN" ]]; then
  if ! CLICKHOUSE_BIN="$(./build.sh | tail -n 1)"; then
    cat > queries/thread_stack.out <<'EOF'
BLOCKED: source-built ClickHouse binary was not produced. See ../commands/source_build_probe.out.
EOF
    cat > queries/thread_stack_symbols.out <<'EOF'
BLOCKED: source-built ClickHouse binary was not produced. See ../commands/source_build_probe.out.
EOF
    cat > queries/thread_stack_fileline.out <<'EOF'
BLOCKED: source-built ClickHouse binary was not produced. See ../commands/source_build_probe.out.
EOF
    ./minimal_impl/run.sh
    echo "BLOCKED: source-built ClickHouse binary was not produced. Default minimal impl output was refreshed." >&2
    exit 2
  fi
fi

test -x "$CLICKHOUSE_BIN"
mkdir -p tmp

normalize_output() {
  local output="$1"
  sed -i -E \
    -e "s#${VARIANT_DIR}#<scheme>/variants/default#g" \
    -e "s#${SCHEME_DIR}#<scheme>#g" \
    -e "s#${REPO_ROOT}#<repo>#g" \
    -e 's#[^[:space:]]*/schemes/ck-system-stack-trace-default/build/default#<scheme>/variants/default/build/default#g' \
    -e 's#[^[:space:]]*/schemes/ck-system-stack-trace/build/default#<scheme>/variants/default/build/default#g' \
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
run_query queries/thread_stack_symbols.sql
run_query queries/thread_stack_fileline.sql

./commands/clickhouse_metadata.sh "$CLICKHOUSE_BIN" > commands/clickhouse_metadata.out
normalize_output commands/clickhouse_metadata.out

"$SCHEME_DIR/minimal_impl/default/run.sh"

echo "wrote ClickHouse default source-build outputs under $VARIANT_DIR"
