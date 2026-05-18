#!/usr/bin/env bash
set -euo pipefail

COMMAND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEME_DIR="$(cd "$COMMAND_DIR/.." && pwd)"
REPO_ROOT="$(git -C "$SCHEME_DIR" rev-parse --show-toplevel)"

CLICKHOUSE_BIN="${CLICKHOUSE_BIN:?CLICKHOUSE_BIN must point to a source-built clickhouse binary}"
CLICKHOUSE_SRC="${CLICKHOUSE_SRC:-$REPO_ROOT/repos/source/ClickHouse-v26.3.10.62-lts}"
CONFIG_FILE="$CLICKHOUSE_SRC/programs/server/config.xml"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "BLOCKED: ClickHouse server config not found: $CONFIG_FILE"
  exit 2
fi

port_open() {
  local port="$1"
  timeout 1 bash -c "</dev/tcp/127.0.0.1/$port" >/dev/null 2>&1
}

pick_port() {
  local start="$1"
  local end=$((start + 200))
  local port
  for port in $(seq "$start" "$end"); do
    if ! port_open "$port"; then
      echo "$port"
      return 0
    fi
  done
  return 1
}

TCP_PORT="${CK_PROFILER_TCP_PORT:-$(pick_port 19000)}"
HTTP_PORT="${CK_PROFILER_HTTP_PORT:-$(pick_port 19123)}"
INTERSERVER_PORT="${CK_PROFILER_INTERSERVER_PORT:-$(pick_port 19009)}"
BASE="$SCHEME_DIR/tmp/server-cpu"
QUERY_ID="${CK_PROFILER_QUERY_ID:-ck_query_profiler_cpu_sample}"
ROWS="${CK_PROFILER_ROWS:-100000000}"
CPU_PERIOD_NS="${CK_PROFILER_CPU_PERIOD_NS:-1000000}"

rm -rf "$BASE"
mkdir -p \
  "$BASE/data" \
  "$BASE/tmp" \
  "$BASE/access" \
  "$BASE/logs" \
  "$BASE/user_files" \
  "$BASE/format_schemas" \
  "$BASE/top_level_domains"

client() {
  "$CLICKHOUSE_BIN" client --host 127.0.0.1 --port "$TCP_PORT" "$@"
}

cleanup() {
  client --query "SYSTEM SHUTDOWN" >/dev/null 2>&1 || true
  if [[ -f "$BASE/server.pid" ]]; then
    local pid
    pid="$(cat "$BASE/server.pid" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      kill -TERM "$pid" >/dev/null 2>&1 || true
    fi
  fi
}
trap cleanup EXIT

"$CLICKHOUSE_BIN" server \
  --daemon \
  --config-file "$CONFIG_FILE" \
  --pid-file "$BASE/server.pid" \
  -- \
  --path="$BASE/data/" \
  --tmp_path="$BASE/tmp/" \
  --user_files_path="$BASE/user_files/" \
  --format_schema_path="$BASE/format_schemas/" \
  --top_level_domains_path="$BASE/top_level_domains/" \
  --user_directories.local_directory.path="$BASE/access/" \
  --logger.log="$BASE/logs/server.log" \
  --logger.errorlog="$BASE/logs/server.err.log" \
  --logger.level=warning \
  --http_port="$HTTP_PORT" \
  --tcp_port="$TCP_PORT" \
  --interserver_http_port="$INTERSERVER_PORT" \
  --mysql_port=0 \
  --postgresql_port=0 \
  --keeper_server.tcp_port=0 \
  --mlock_executable=false

ready=0
for _ in $(seq 1 30); do
  if client --query "SELECT 1" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done

if [[ "$ready" != "1" ]]; then
  echo "BLOCKED: ClickHouse server did not become ready on tcp port $TCP_PORT"
  tail -n 80 "$BASE/logs/server.err.log" 2>/dev/null || true
  exit 2
fi

render_query() {
  local input="$1"
  sed \
    -e "s/{query_id}/$QUERY_ID/g" \
    -e "s/{rows}/$ROWS/g" \
    -e "s/{cpu_period_ns}/$CPU_PERIOD_NS/g" \
    "$input"
}

workload_query="$(render_query "$SCHEME_DIR/queries/workload_cpu.sql")"
summary_query="$(render_query "$SCHEME_DIR/queries/trace_log_summary.sql")"
symbols_query="$(render_query "$SCHEME_DIR/queries/trace_log_symbols.sql")"

echo "clickhouse_binary=$CLICKHOUSE_BIN"
echo "clickhouse_version=$("$CLICKHOUSE_BIN" --version)"
echo "source_config=$CONFIG_FILE"
echo "tcp_port=$TCP_PORT"
echo "query_id=$QUERY_ID"
echo "cpu_period_ns=$CPU_PERIOD_NS"
echo "rows=$ROWS"
echo
echo "workload_query:"
printf '%s\n' "$workload_query"
echo
echo "workload_result:"
client --query_id "$QUERY_ID" --query "$workload_query"

client --query "SYSTEM FLUSH LOGS"

sample_count="$(client --query "SELECT count() FROM system.trace_log WHERE query_id = '$QUERY_ID'")"
if [[ "$sample_count" == "0" ]]; then
  echo "BLOCKED: system.trace_log has no samples for query_id=$QUERY_ID"
  tail -n 80 "$BASE/logs/server.err.log" 2>/dev/null || true
  exit 2
fi

echo
echo "trace_log_summary:"
client --query "$summary_query"

echo
echo "trace_log_symbol_sample:"
client --allow_introspection_functions=1 --query "$symbols_query"
