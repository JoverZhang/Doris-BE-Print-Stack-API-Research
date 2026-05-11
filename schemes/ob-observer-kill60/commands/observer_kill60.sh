#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="${REPO_ROOT:-$(git -C "$SCHEME_DIR" rev-parse --show-toplevel)}"
source "$REPO_ROOT/shared/oceanbase/observer_runtime.sh"
cd "$SCHEME_DIR"

observer="${OBSERVER_BIN:-}"
if ! ob_require_executable "source-built observer binary" "$observer"; then
  cat <<'OUT'
Run schemes/ob-observer-kill60/build.sh first or set OBSERVER_BIN.
No release binary is used for this real-observer output.
OUT
  exit 2
fi

if [[ "${OB_OBSERVER_KILL60_IN_PODMAN:-0}" != "1" ]]; then
  ob_require_under_repo "OBSERVER_BIN" "$observer" "$REPO_ROOT" || exit 2
  command -v podman >/dev/null 2>&1 || {
    echo "BLOCKED: podman is required to run the source-built OceanBase observer runtime."
    exit 2
  }

  observer_rel="$(ob_repo_relpath "$observer" "$REPO_ROOT")"
  ob_podman_with_timeout ob-kill60 --rm "${OB_PODMAN_PTRACE_SECURITY_ARGS[@]}" \
    -v "$REPO_ROOT:/work" -w /work \
    -e REPO_ROOT=/work \
    -e "OBSERVER_BIN=/work/$observer_rel" \
    -e OB_OBSERVER_KILL60_IN_PODMAN=1 \
    docker.io/library/almalinux:8 bash -lc '
set -euo pipefail
dnf install -y ncurses-compat-libs zlib libaio procps-ng file >/tmp/observer-kill60-yum.log 2>&1
schemes/ob-observer-kill60/commands/observer_kill60.sh
'
  exit $?
fi

ob_print_observer_binary_metadata "$observer"

run_dir="$SCHEME_DIR/tmp/observer-kill60"
ob_prepare_observer_run_dir "$run_dir"

ob_start_observer "$observer" "$run_dir" 29881 29882
trap 'ob_stop_observer' EXIT

ob_wait_observer_ready "$run_dir" "$OB_OBSERVER_BG_PID"
ob_resolve_observer_pid "$run_dir" "$OB_OBSERVER_BG_PID"
observer_pid="$OB_OBSERVER_PID"
echo "observer_pid=$observer_pid"
echo "observer_pid_source=$OB_OBSERVER_PID_SOURCE"
echo "mysql_port=$OB_OBSERVER_MYSQL_PORT"
echo "rpc_port=$OB_OBSERVER_RPC_PORT"
echo "rs_list=$OB_OBSERVER_RS_LIST"

cd "$run_dir"
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
