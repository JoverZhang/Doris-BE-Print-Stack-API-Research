#!/usr/bin/env bash

if [[ -n "${OB_OBSERVER_RUNTIME_SH_INCLUDED:-}" ]]; then
  return 0
fi
OB_OBSERVER_RUNTIME_SH_INCLUDED=1

OB_PODMAN_PTRACE_SECURITY_ARGS=(
  --cap-add=SYS_PTRACE
  --security-opt seccomp=unconfined
  --security-opt label=disable
)

ob_default_observer_optstr() {
  printf '%s\n' "memory_limit=6G,system_memory=1G,__min_full_resource_pool_memory=1073741824,datafile_size=2G,log_disk_size=2G,datafile_next=2G,datafile_maxsize=8G,production_mode=false,devname=lo"
}

ob_require_executable() {
  local name="$1"
  local path="$2"
  if [[ -z "$path" || ! -x "$path" ]]; then
    echo "BLOCKED: $name is unavailable or not executable: ${path:-<unset>}"
    return 2
  fi
}

ob_require_under_repo() {
  local name="$1"
  local path="$2"
  local repo_root="$3"
  case "$path" in
    "$repo_root"/*) ;;
    *)
      echo "BLOCKED: $name must be under repo root for podman runner: $path"
      return 2
      ;;
  esac
}

ob_repo_relpath() {
  local path="$1"
  local repo_root="$2"
  printf '%s\n' "${path#"$repo_root"/}"
}

ob_print_observer_binary_metadata() {
  local observer="$1"
  echo "observer_binary=$observer"
  if command -v stat >/dev/null 2>&1; then
    echo "observer_binary_size_bytes=$(stat -c '%s' "$observer")"
  fi
  if command -v file >/dev/null 2>&1; then
    echo "observer_binary_file=$(file -b "$observer")"
  fi
}

ob_prepare_observer_run_dir() {
  local run_dir="$1"
  rm -rf "$run_dir"
  mkdir -p "$run_dir"
  mkdir -p "$run_dir/store/clog" "$run_dir/store/slog" "$run_dir/store/sstable" "$run_dir/run" "$run_dir/log"
}

ob_start_observer() {
  local observer="$1"
  local run_dir="$2"
  local default_mysql_port="$3"
  local default_rpc_port="$4"

  OB_OBSERVER_RUN_DIR="$run_dir"
  OB_OBSERVER_MYSQL_PORT="${OB_MYSQL_PORT:-$default_mysql_port}"
  OB_OBSERVER_RPC_PORT="${OB_RPC_PORT:-$default_rpc_port}"
  OB_OBSERVER_RS_LIST="${OB_RS_LIST:-127.0.0.1:${OB_OBSERVER_RPC_PORT}:${OB_OBSERVER_MYSQL_PORT}}"
  OB_OBSERVER_OPTSTR="${OB_OPTSTR:-$(ob_default_observer_optstr)}"

  local cwd
  cwd="$(pwd)"
  cd "$run_dir"
  "$observer" -N -P "$OB_OBSERVER_RPC_PORT" -p "$OB_OBSERVER_MYSQL_PORT" -z zone1 -n repro -c 1 \
    -d "$run_dir/store" -i lo -I 127.0.0.1 -r "$OB_OBSERVER_RS_LIST" -o "$OB_OBSERVER_OPTSTR" \
    > observer.stdout 2> observer.stderr &
  OB_OBSERVER_BG_PID=$!
  cd "$cwd"
}

ob_stop_observer() {
  if [[ -n "${OB_OBSERVER_PID:-}" ]]; then
    kill "$OB_OBSERVER_PID" 2>/dev/null || true
  fi
  if [[ -n "${OB_OBSERVER_BG_PID:-}" ]]; then
    kill "$OB_OBSERVER_BG_PID" 2>/dev/null || true
    wait "$OB_OBSERVER_BG_PID" 2>/dev/null || true
  fi
}

ob_wait_observer_ready() {
  local run_dir="$1"
  local bg_pid="$2"
  local ready_marker="${3:-success to start signal worker and handle}"
  local retries="${4:-120}"

  for _ in $(seq 1 "$retries"); do
    if kill -0 "$bg_pid" 2>/dev/null \
      && { [[ -f "$run_dir/run/observer.pid" ]] || grep -q "$ready_marker" "$run_dir/log/observer.log" 2>/dev/null; }; then
      return 0
    fi
    sleep 1
  done

  if ! kill -0 "$bg_pid" 2>/dev/null; then
    echo "FAIL: observer exited before signal-worker startup"
    sed -n '1,120p' "$run_dir/observer.stderr" || true
    return 2
  fi

  echo "FAIL: observer did not report readiness before timeout"
  sed -n '1,120p' "$run_dir/observer.stderr" || true
  return 2
}

ob_resolve_observer_pid() {
  local run_dir="$1"
  local bg_pid="$2"

  if [[ -f "$run_dir/run/observer.pid" ]]; then
    OB_OBSERVER_PID="$(cat "$run_dir/run/observer.pid")"
    OB_OBSERVER_PID_SOURCE="run/observer.pid"
  else
    OB_OBSERVER_PID="$bg_pid"
    OB_OBSERVER_PID_SOURCE="background child pid; run/observer.pid was not created in -N mode"
  fi
}
