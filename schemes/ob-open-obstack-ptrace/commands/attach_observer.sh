#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(git -C "$SCHEME_DIR" rev-parse --show-toplevel)"
obstack_bin="${OBSTACK_BIN:-$REPO_ROOT/repos/source/obstack-master/build_release/src/obstack}"
observer_bin="${OBSERVER_BIN:-$REPO_ROOT/repos/source/oceanbase-v4.5.0_CE/build_release/src/observer/observer}"

if [[ ! -x "$obstack_bin" ]]; then
  cat <<'OUT'
BLOCKED: source-built open obstack binary is unavailable.
See commands/source_build_probe.out for the current source-build blocker.
OUT
  exit 2
fi

if [[ ! -x "$observer_bin" ]]; then
  cat <<'OUT'
BLOCKED: source-built OceanBase observer binary is unavailable.
Run scheme ob-observer-kill60 first or set OBSERVER_BIN to the source-built observer.
OUT
  exit 2
fi

case "$obstack_bin" in "$REPO_ROOT"/*) ;; *) echo "BLOCKED: OBSTACK_BIN must be under repo root for podman runner."; exit 2 ;; esac
case "$observer_bin" in "$REPO_ROOT"/*) ;; *) echo "BLOCKED: OBSERVER_BIN must be under repo root for podman runner."; exit 2 ;; esac

obstack_rel="${obstack_bin#"$REPO_ROOT"/}"
observer_rel="${observer_bin#"$REPO_ROOT"/}"

podman run --rm --cap-add=SYS_PTRACE --security-opt seccomp=unconfined --security-opt label=disable \
  -v "$REPO_ROOT:/work" -w /work \
  -e "OBSTACK_BIN=/work/$obstack_rel" \
  -e "OBSERVER_BIN=/work/$observer_rel" \
  -e "OBSTACK_ATTACH_TIMEOUT=${OBSTACK_ATTACH_TIMEOUT:-180}" \
  docker.io/library/almalinux:8 bash -lc '
set -euo pipefail
dnf install -y ncurses-compat-libs zlib libaio procps-ng file >/tmp/open-obstack-observer-yum.log 2>&1

run_dir=/work/schemes/ob-open-obstack-ptrace/tmp/observer-attach
rm -rf "$run_dir"
mkdir -p "$run_dir"
cd "$run_dir"
mkdir -p store/clog store/slog store/sstable run log

mysql_port="${OB_MYSQL_PORT:-29981}"
rpc_port="${OB_RPC_PORT:-29982}"
rs_list="${OB_RS_LIST:-127.0.0.1:${rpc_port}:${mysql_port}}"
optstr="${OB_OPTSTR:-memory_limit=6G,system_memory=1G,__min_full_resource_pool_memory=1073741824,datafile_size=2G,log_disk_size=2G,datafile_next=2G,datafile_maxsize=8G,production_mode=false,devname=lo}"

"$OBSERVER_BIN" -N -P "$rpc_port" -p "$mysql_port" -z zone1 -n repro -c 1 \
  -d "$run_dir/store" -i lo -I 127.0.0.1 -r "$rs_list" -o "$optstr" \
  > observer.stdout 2> observer.stderr &
bg=$!
trap "kill $bg 2>/dev/null || true; wait $bg 2>/dev/null || true" EXIT

ready_marker="success to start signal worker and handle"
for _ in $(seq 1 120); do
  if kill -0 "$bg" 2>/dev/null \
    && { [[ -f run/observer.pid ]] || grep -q "$ready_marker" log/observer.log 2>/dev/null; }; then
    break
  fi
  sleep 1
done

if ! kill -0 "$bg" 2>/dev/null; then
  echo "status=FAIL"
  echo "reason=observer exited before attach"
  sed -n "1,120p" observer.stderr || true
  exit 2
fi

observer_pid="$bg"
observer_pid_source="background child pid; run/observer.pid was not created in -N mode"
if [[ -f run/observer.pid ]]; then
  observer_pid="$(cat run/observer.pid)"
  observer_pid_source="run/observer.pid"
fi

raw=/tmp/open-obstack-observer.out
err=/tmp/open-obstack-observer.err
set +e
timeout "$OBSTACK_ATTACH_TIMEOUT" "$OBSTACK_BIN" "$observer_pid" >"$raw" 2>"$err"
rc=$?
set -e

echo "command=$OBSTACK_BIN <source_built_observer_pid>"
echo "observer_pid=$observer_pid"
echo "observer_pid_source=$observer_pid_source"
echo "observer_binary=$OBSERVER_BIN"
echo "observer_binary_file=$(file -b "$OBSERVER_BIN")"
echo "obstack_binary=$OBSTACK_BIN"
echo "obstack_binary_file=$(file -b "$OBSTACK_BIN")"
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
