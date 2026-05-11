#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(git -C "$SCHEME_DIR" rev-parse --show-toplevel)"
source "$REPO_ROOT/shared/oceanbase/observer_runtime.sh"
obstack_bin="${OBSTACK_BIN:-$REPO_ROOT/repos/source/obstack-master/build_release/src/obstack}"
observer_bin="${OBSERVER_BIN:-$REPO_ROOT/repos/source/oceanbase-v4.5.0_CE/build_release/src/observer/observer}"

if ! ob_require_executable "source-built open obstack binary" "$obstack_bin"; then
  cat <<'OUT'
Run schemes/ob-open-obstack-ptrace/build.sh first or set OBSTACK_BIN.
OUT
  exit 2
fi

if ! ob_require_executable "source-built OceanBase observer binary" "$observer_bin"; then
  cat <<'OUT'
Run scheme ob-observer-kill60 first or set OBSERVER_BIN to the source-built observer.
OUT
  exit 2
fi

ob_require_under_repo "OBSTACK_BIN" "$obstack_bin" "$REPO_ROOT" || exit 2
ob_require_under_repo "OBSERVER_BIN" "$observer_bin" "$REPO_ROOT" || exit 2

obstack_rel="$(ob_repo_relpath "$obstack_bin" "$REPO_ROOT")"
observer_rel="$(ob_repo_relpath "$observer_bin" "$REPO_ROOT")"
export OB_PODMAN_TIMEOUT_SECONDS="${OB_PODMAN_TIMEOUT_SECONDS:-300}"

ob_podman_with_timeout ob-open-obstack --rm "${OB_PODMAN_PTRACE_SECURITY_ARGS[@]}" \
  -v "$REPO_ROOT:/work" -w /work \
  -e "OBSTACK_BIN=/work/$obstack_rel" \
  -e "OBSERVER_BIN=/work/$observer_rel" \
  -e "OBSTACK_ATTACH_TIMEOUT=${OBSTACK_ATTACH_TIMEOUT:-180}" \
  -e "OB_RUNTIME_HELPER=/work/shared/oceanbase/observer_runtime.sh" \
  docker.io/library/almalinux:8 bash -lc '
set -euo pipefail
source "$OB_RUNTIME_HELPER"
dnf install -y --setopt=timeout=20 --setopt=retries=1 ncurses-compat-libs >/tmp/open-obstack-observer-yum.log 2>&1

describe_file() {
  if command -v file >/dev/null 2>&1; then
    file -b "$1"
  else
    printf "%s\n" "file(1) unavailable in runtime image"
  fi
}

run_dir=/work/schemes/ob-open-obstack-ptrace/tmp/observer-attach
ob_prepare_observer_run_dir "$run_dir"
ob_start_observer "$OBSERVER_BIN" "$run_dir" 29981 29982
trap "ob_stop_observer" EXIT

if ! ob_wait_observer_ready "$run_dir" "$OB_OBSERVER_BG_PID"; then
  echo "status=FAIL"
  echo "reason=observer exited before attach"
  exit 2
fi

ob_resolve_observer_pid "$run_dir" "$OB_OBSERVER_BG_PID"

raw=/tmp/open-obstack-observer.out
err=/tmp/open-obstack-observer.err
set +e
timeout "$OBSTACK_ATTACH_TIMEOUT" "$OBSTACK_BIN" "$OB_OBSERVER_PID" >"$raw" 2>"$err"
rc=$?
set -e

echo "command=$OBSTACK_BIN <source_built_observer_pid>"
echo "observer_pid=$OB_OBSERVER_PID"
echo "observer_pid_source=$OB_OBSERVER_PID_SOURCE"
echo "observer_binary=$OBSERVER_BIN"
echo "observer_binary_file=$(describe_file "$OBSERVER_BIN")"
echo "obstack_binary=$OBSTACK_BIN"
echo "obstack_binary_file=$(describe_file "$OBSTACK_BIN")"
echo "runtime=podman almalinux:8 with SYS_PTRACE and seccomp=unconfined"
echo "exit_code=$rc"
echo "obstack_output_bytes=$(wc -c <"$raw")"
echo "obstack_stderr_bytes=$(wc -c <"$err")"
echo "obstack_output_lines=$(wc -l <"$raw")"
echo "ptrace_denied_lines=$(grep -c "Operation not permitted" "$err" || true)"
if [[ "$rc" -eq 0 && -s "$raw" ]]; then
  echo "status=PASS"
else
  echo "status=FAIL"
fi
echo
echo "obstack_stderr_sample:"
sed -n "1,80p" "$err"
echo
echo "obstack_stdout_sample:"
sed -n "1,120p" "$raw"

if [[ "$rc" -ne 0 || ! -s "$raw" ]]; then
  exit 1
fi
'
