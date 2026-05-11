#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(git -C "$SCHEME_DIR" rev-parse --show-toplevel)"
source "$REPO_ROOT/shared/oceanbase/observer_runtime.sh"
bin="${OCP_OBSTACK_BIN:-$SCHEME_DIR/.cache/rpm-el8/usr/bin/obstack}"
observer_pid="${OBSERVER_PID:-}"
observer_bin="${OBSERVER_BIN:-$REPO_ROOT/repos/source/oceanbase-v4.5.0_CE/build_release/src/observer/observer}"

if ! ob_require_executable "OCP obstack binary" "$bin"; then
  cat <<'OUT'
Run commands/provenance_probe.sh first or set OCP_OBSTACK_BIN.
OUT
  exit 2
fi

collect_obstack() {
  local obstack_bin="$1"
  local target_pid="$2"
  local raw="$3"
  local stderr_file="$4"

  set +e
  "$obstack_bin" -o "$target_pid" >"$raw" 2>"$stderr_file"
  local rc=$?
  set -e

  local raw_bytes stderr_bytes ptrace_denied_lines
  raw_bytes="$(wc -c <"$raw")"
  stderr_bytes="$(wc -c <"$stderr_file")"
  ptrace_denied_lines="$(grep -c 'Operation not permitted' "$stderr_file" || true)"

  echo "exit_code=${rc}"
  echo "obstack_output_bytes=${raw_bytes}"
  echo "obstack_stderr_bytes=${stderr_bytes}"
  echo "ptrace_denied_lines=${ptrace_denied_lines}"

  if [[ "$raw_bytes" -gt 0 ]]; then
    echo "status=PASS"
    echo "obstack_output_lines=$(wc -l <"$raw")"
    echo
    echo "obstack_stderr_sample:"
    sed -n '1,40p' "$stderr_file"
    echo
    echo "obstack_stdout_sample:"
    sed -n '1,120p' "$raw"
    return 0
  fi

  echo "status=FAIL"
  echo "reason=OCP obstack produced no stdout stack output."
  echo
  echo "obstack_stderr_sample:"
  sed -n '1,120p' "$stderr_file"
  return 1
}

if [[ -n "$observer_pid" ]]; then
  echo "command=${bin} -o ${observer_pid}"
  tmp_dir="${TMPDIR:-$SCHEME_DIR/tmp}/obstack_collect.$$"
  mkdir -p "$tmp_dir"
  collect_obstack "$bin" "$observer_pid" "$tmp_dir/obstack.raw" "$tmp_dir/obstack.stderr"
  exit $?
fi

if ! ob_require_executable "source-built OceanBase observer binary" "$observer_bin"; then
  cat <<'OUT'
Start the source-built OceanBase observer first, set OBSERVER_BIN to it, or rerun with OBSERVER_PID=<pid>.
OUT
  exit 2
fi

ob_require_under_repo "OCP_OBSTACK_BIN" "$bin" "$REPO_ROOT" || exit 2
ob_require_under_repo "OBSERVER_BIN" "$observer_bin" "$REPO_ROOT" || exit 2

bin_rel="$(ob_repo_relpath "$bin" "$REPO_ROOT")"
observer_rel="$(ob_repo_relpath "$observer_bin" "$REPO_ROOT")"

ob_podman_with_timeout ob-ocp-obstack --rm "${OB_PODMAN_PTRACE_SECURITY_ARGS[@]}" \
  -v "$REPO_ROOT:/work" -w /work \
  -e "OCP_OBSTACK_BIN=/work/$bin_rel" \
  -e "OBSERVER_BIN=/work/$observer_rel" \
  -e "OB_RUNTIME_HELPER=/work/shared/oceanbase/observer_runtime.sh" \
  docker.io/library/almalinux:8 bash -lc '
set -euo pipefail
source "$OB_RUNTIME_HELPER"
dnf install -y ncurses-compat-libs zlib libaio procps-ng file >/tmp/ocp-obstack-yum.log 2>&1

run_dir=/work/schemes/ob-ocp-obstack/tmp/observer-collect
ob_prepare_observer_run_dir "$run_dir"
ob_start_observer "$OBSERVER_BIN" "$run_dir" 30881 30882
trap "ob_stop_observer" EXIT

if ! ob_wait_observer_ready "$run_dir" "$OB_OBSERVER_BG_PID"; then
  echo "status=FAIL"
  echo "reason=observer exited before OCP obstack collection"
  exit 2
fi

ob_resolve_observer_pid "$run_dir" "$OB_OBSERVER_BG_PID"

raw=/tmp/ocp-obstack.out
err=/tmp/ocp-obstack.err

echo "observer_pid=$OB_OBSERVER_PID"
echo "observer_pid_source=$OB_OBSERVER_PID_SOURCE"
ob_print_observer_binary_metadata "$OBSERVER_BIN"
echo "obstack_binary=$OCP_OBSTACK_BIN"
echo "obstack_binary_file=$(file -b "$OCP_OBSTACK_BIN")"
echo "podman_security=--cap-add=SYS_PTRACE --security-opt seccomp=unconfined --security-opt label=disable"
echo "mysql_port=$OB_OBSERVER_MYSQL_PORT"
echo "rpc_port=$OB_OBSERVER_RPC_PORT"
echo "rs_list=$OB_OBSERVER_RS_LIST"
echo "command=$OCP_OBSTACK_BIN -o $OB_OBSERVER_PID"
echo

set +e
"$OCP_OBSTACK_BIN" -o "$OB_OBSERVER_PID" >"$raw" 2>"$err"
rc=$?
set -e

raw_bytes="$(wc -c <"$raw")"
stderr_bytes="$(wc -c <"$err")"
ptrace_denied_lines="$(grep -c "Operation not permitted" "$err" || true)"

echo "obstack_output_bytes=$raw_bytes"
echo "obstack_stderr_bytes=$stderr_bytes"
echo "ptrace_denied_lines=$ptrace_denied_lines"
if [[ "$rc" -eq 0 && "$raw_bytes" -gt 0 ]]; then
  echo "status=PASS"
else
  echo "status=FAIL"
fi
echo "obstack_output_lines=$(wc -l <"$raw")"
echo
echo "obstack_stderr_sample:"
sed -n "1,40p" "$err"
echo
echo "obstack_stdout_sample:"
sed -n "1,120p" "$raw"

if [[ "$rc" -ne 0 || "$raw_bytes" -eq 0 ]]; then
  exit 1
fi
'
