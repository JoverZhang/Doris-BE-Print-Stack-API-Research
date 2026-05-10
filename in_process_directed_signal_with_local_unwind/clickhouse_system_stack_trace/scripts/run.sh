#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$CASE_DIR"

rm -rf data tmp logs access user_files format_schemas outputs
mkdir -p data tmp logs access user_files format_schemas outputs

./scripts/download_clickhouse.sh > outputs/download_clickhouse.out 2> outputs/download_clickhouse.err
./scripts/download_clickhouse_debug.sh > outputs/download_clickhouse_debug.out 2> outputs/download_clickhouse_debug.err

SERVER_CMD_PID=""
cleanup() {
  set +e
  if [[ -f data/status ]]; then
    pid="$(awk '/^PID:/ {print $2}' data/status)"
    [[ -n "${pid:-}" ]] && kill "$pid" 2>/dev/null
  fi
  [[ -n "$SERVER_CMD_PID" ]] && kill "$SERVER_CMD_PID" 2>/dev/null
  sleep 1
  if [[ -f data/status ]]; then
    pid="$(awk '/^PID:/ {print $2}' data/status)"
    [[ -n "${pid:-}" ]] && kill -9 "$pid" 2>/dev/null
  fi
  [[ -n "$SERVER_CMD_PID" ]] && kill -9 "$SERVER_CMD_PID" 2>/dev/null
}
trap cleanup EXIT

./bin/clickhouse server --config-file=config/config.xml > logs/stdout.log 2> logs/stderr.log &
SERVER_CMD_PID="$!"

CLIENT=(./bin/clickhouse client --host 127.0.0.1 --port 19000)

for _ in $(seq 1 60); do
  if timeout 2 "${CLIENT[@]}" --query 'SELECT version()' > outputs/version.txt 2> outputs/client.err; then
    break
  fi
  sleep 1
done

if [[ ! -s outputs/version.txt ]]; then
  echo "ClickHouse server did not become ready" >&2
  tail -120 logs/stderr.log logs/error.log outputs/client.err >&2 || true
  exit 1
fi

"${CLIENT[@]}" --query "DESCRIBE TABLE system.stack_trace FORMAT Vertical" \
  > outputs/system_stack_trace_describe.txt

"${CLIENT[@]}" --query "SELECT name, value, changed FROM system.settings WHERE name='storage_system_stack_trace_pipe_read_timeout_ms' FORMAT Vertical" \
  > outputs/stack_trace_setting.txt

"${CLIENT[@]}" --query "SELECT thread_name, thread_id, query_id, length(trace) AS trace_len, arraySlice(trace,1,5) AS trace_head, untracked_memory FROM system.stack_trace ORDER BY thread_id LIMIT 10 FORMAT Vertical" \
  > outputs/raw_trace.txt

"${CLIENT[@]}" --query "SELECT count() AS rows, countIf(length(trace)>0) AS with_trace, min(length(trace)) AS min_trace, max(length(trace)) AS max_trace FROM system.stack_trace FORMAT Vertical" \
  > outputs/system_stack_trace_counts.txt

"${CLIENT[@]}" --query "SELECT thread_name, thread_id, arrayMap(x -> demangle(addressToSymbol(x)), arraySlice(trace, 1, 10)) AS symbols FROM system.stack_trace WHERE length(trace) > 0 LIMIT 5 FORMAT Vertical" \
  > outputs/symbol_names.txt

"${CLIENT[@]}" --query "SELECT thread_name, thread_id, arrayMap(x -> addressToLine(x), arraySlice(trace, 1, 10)) AS lines FROM system.stack_trace WHERE length(trace) > 0 LIMIT 5 FORMAT Vertical" \
  > outputs/file_lines.txt

"${CLIENT[@]}" --query "WITH arrayMap(x -> addressToLine(x), trace) AS all_lines, arrayFilter(x -> (x != '' AND x NOT LIKE '%/bin/clickhouse' AND x NOT LIKE '%/bin/clickhouse.debug'), all_lines) AS source_lines SELECT thread_name, thread_id, query_id, arrayStringConcat(if(notEmpty(source_lines), source_lines, all_lines), '\n') AS res FROM system.stack_trace WHERE length(trace) > 0 LIMIT 3 FORMAT Vertical" \
  > outputs/file_lines_filtered.txt

"${CLIENT[@]}" --query "SELECT thread_name, thread_id, arrayMap(x -> addressToLineWithInlines(x), arraySlice(trace, 1, 6)) AS inline_lines FROM system.stack_trace WHERE length(trace) > 0 LIMIT 3 FORMAT Vertical" \
  > outputs/inline_lines.txt

./scripts/run_fp_no_fp_control.sh > outputs/fp_control_run.out 2> outputs/fp_control_run.err

redact_case_dir() {
  local file tmp line
  for file in "$@"; do
    [[ -f "$file" ]] || continue
    tmp="${file}.tmp"
    while IFS= read -r line || [[ -n "$line" ]]; do
      printf '%s\n' "${line//$CASE_DIR/<case-dir>}"
    done < "$file" > "$tmp"
    mv "$tmp" "$file"
  done
}

redact_case_dir outputs/*.txt outputs/fp_control/*.txt

{
  echo "version=$(cat outputs/version.txt)"
  grep -E 'rows:|with_trace:|min_trace:|max_trace:' outputs/system_stack_trace_counts.txt || true
  echo "debug_info_layout:"
  sed 's/^/  /' outputs/debug_info_layout.txt
  echo "fp_no_fp_depth_summary:"
  sed 's/^/  /' outputs/fp_control/depth_summary.csv
} > outputs/phase1b_summary.txt

echo "ClickHouse Phase 1-B outputs written under ${CASE_DIR}/outputs"
