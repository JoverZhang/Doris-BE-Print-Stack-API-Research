#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCHEME_DIR" rev-parse --show-toplevel)"
cd "$SCHEME_DIR"

mkdir -p commands tmp

CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-}"
if [[ -z "$CLICKHOUSE_BIN" ]]; then
  candidate="$REPO_ROOT/schemes/ck-system-stack-trace/build/default/programs/clickhouse"
  if [[ -x "$candidate" ]]; then
    CLICKHOUSE_BIN="$candidate"
  elif ! CLICKHOUSE_BIN="$("$REPO_ROOT/schemes/ck-system-stack-trace/variants/default/build.sh" | tail -n 1)"; then
    cat > commands/query_profiler_cpu.out <<'EOF'
BLOCKED: source-built ClickHouse binary was not produced. Run schemes/ck-system-stack-trace/variants/default/build.sh and check stderr.
EOF
    echo "BLOCKED: source-built ClickHouse binary was not produced." >&2
    exit 2
  fi
fi

test -x "$CLICKHOUSE_BIN"

normalize_output() {
  local output="$1"
  sed -i -E \
    -e "s#${SCHEME_DIR}#<scheme>#g" \
    -e "s#${REPO_ROOT}#<repo>#g" \
    -e 's#/home/mira/.slock/agents/[^[:space:]]*/projects/[^[:space:]]*/#<repo>/#g' \
    -e 's/[[:space:]]+$//' \
    "$output"
}

CLICKHOUSE_BIN="$CLICKHOUSE_BIN" ./commands/query_profiler_cpu.sh > commands/query_profiler_cpu.out
normalize_output commands/query_profiler_cpu.out

if grep -q '^BLOCKED:' commands/query_profiler_cpu.out; then
  echo "BLOCKED: ClickHouse query profiler evidence was not produced." >&2
  exit 2
fi

echo "wrote ClickHouse query profiler outputs under $SCHEME_DIR"
