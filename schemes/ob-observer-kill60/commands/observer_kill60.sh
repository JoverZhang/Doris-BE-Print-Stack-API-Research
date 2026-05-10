#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCHEME_DIR"

observer="${OBSERVER_BIN:-}"
if [[ -z "$observer" || ! -x "$observer" ]]; then
  cat <<'OUT'
BLOCKED: source-built observer binary is unavailable.
See commands/source_build_probe.out for the current source-build blocker.
No release binary or synthetic target is used for this real-observer output.
OUT
  exit 2
fi

echo "observer_binary=$observer"
if command -v stat >/dev/null 2>&1; then
  echo "observer_binary_size_bytes=$(stat -c '%s' "$observer")"
fi
if command -v file >/dev/null 2>&1; then
  echo "observer_binary_file=$(file -b "$observer")"
fi

run_dir="$SCHEME_DIR/tmp/observer-kill60"
rm -rf "$run_dir"
mkdir -p "$run_dir"
cd "$run_dir"
mkdir -p store/clog store/slog store/sstable run log

mysql_port="${OB_MYSQL_PORT:-29881}"
rpc_port="${OB_RPC_PORT:-29882}"
rs_list="${OB_RS_LIST:-127.0.0.1:${rpc_port}:${mysql_port}}"
optstr="${OB_OPTSTR:-memory_limit=6G,system_memory=1G,__min_full_resource_pool_memory=1073741824,datafile_size=2G,log_disk_size=2G,datafile_next=2G,datafile_maxsize=8G,production_mode=false,devname=lo}"

"$observer" -N -P "$rpc_port" -p "$mysql_port" -z zone1 -n repro -c 1 \
  -d "$run_dir/store" -i lo -I 127.0.0.1 -r "$rs_list" -o "$optstr" \
  > observer.stdout 2> observer.stderr &
pid=$!
observer_pid=""
trap 'if [[ -n "${observer_pid:-}" ]]; then kill "$observer_pid" 2>/dev/null || true; fi; kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT

ready_marker="success to start signal worker and handle"
for _ in $(seq 1 120); do
  if kill -0 "$pid" 2>/dev/null \
    && { [[ -f run/observer.pid ]] || grep -q "$ready_marker" log/observer.log 2>/dev/null; }; then
    break
  fi
  sleep 1
done

if ! kill -0 "$pid" 2>/dev/null; then
  echo "FAIL: observer exited before signal-worker startup"
  sed -n '1,80p' observer.stderr || true
  exit 2
fi

if [[ -f run/observer.pid ]]; then
  observer_pid="$(cat run/observer.pid)"
  observer_pid_source="run/observer.pid"
else
  observer_pid="$pid"
  observer_pid_source="background child pid; run/observer.pid was not created in -N mode"
fi
echo "observer_pid=$observer_pid"
echo "observer_pid_source=$observer_pid_source"
echo "mysql_port=$mysql_port"
echo "rpc_port=$rpc_port"
echo "rs_list=$rs_list"
kill -60 "$observer_pid"

for _ in $(seq 1 60); do
  stack_file="$(ls -1t stack."$observer_pid".* 2>/dev/null | head -n 1 || true)"
  [[ -n "$stack_file" ]] && break
  sleep 1
done

if [[ -z "${stack_file:-}" ]]; then
  echo "FAIL: kill -60 did not produce stack file for observer pid=$observer_pid"
  sed -n '1,120p' observer.stderr || true
  exit 2
fi

for _ in $(seq 1 20); do
  grep -q '^tid:' "$stack_file" && break
  sleep 0.5
done

if ! grep -q '^tid:' "$stack_file"; then
  echo "FAIL: stack file exists but does not contain thread stack lines"
  echo "stack_file=$stack_file"
  sed -n '1,80p' "$stack_file" || true
  exit 2
fi

echo "status=PASS"
echo "stack_file=$stack_file"
echo "stack_file_bytes=$(stat -c '%s' "$stack_file")"
echo "stack_tid_count=$(grep -c '^tid:' "$stack_file")"
echo
echo "maps_head:"
sed -n '1,10p' "$stack_file"
echo
echo "thread_stack_sample:"
grep '^tid:' "$stack_file" | sed -n '1,60p'
