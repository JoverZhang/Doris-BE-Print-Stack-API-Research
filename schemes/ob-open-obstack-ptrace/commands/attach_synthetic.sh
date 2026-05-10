#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(git -C "$SCHEME_DIR" rev-parse --show-toplevel)"
obstack_bin="${OBSTACK_BIN:-$REPO_ROOT/repos/source/obstack-master/build_release/src/obstack}"

if [[ ! -x "$obstack_bin" ]]; then
  cat <<'OUT'
BLOCKED: source-built open obstack binary is unavailable.
See commands/source_build_probe.out for the current source-build blocker.
The source-derived minimal_impl proves the ptrace/libunwind-ptrace mechanics, but it is not substituted for this open obstack project-run output.
OUT
  exit 2
fi

case "$obstack_bin" in
  "$REPO_ROOT"/*) ;;
  *) echo "BLOCKED: OBSTACK_BIN must be under repo root for the podman synthetic attach runner."; exit 2 ;;
esac

obstack_rel="${obstack_bin#"$REPO_ROOT"/}"

podman run --rm --cap-add=SYS_PTRACE --security-opt seccomp=unconfined --security-opt label=disable \
  -v "$REPO_ROOT:/work" -w /work \
  -e "OBSTACK_BIN=/work/$obstack_rel" \
  docker.io/library/centos:7 bash -lc '
set -euo pipefail
sed -i s/mirror.centos.org/vault.centos.org/g /etc/yum.repos.d/CentOS-*.repo
sed -i s/^#.*baseurl=http/baseurl=http/g /etc/yum.repos.d/CentOS-*.repo
sed -i s/^mirrorlist=http/#mirrorlist=http/g /etc/yum.repos.d/CentOS-*.repo
yum install -y gcc gcc-c++ glibc-devel libstdc++-devel ncurses-libs zlib file procps-ng >/tmp/obstack-synthetic-yum.log 2>&1

target=/work/schemes/ob-open-obstack-ptrace/.cache/synthetic_target_centos7
mkdir -p "$(dirname "$target")"
g++ -std=c++11 -O1 -g -fno-omit-frame-pointer -pthread \
  /work/schemes/ob-open-obstack-ptrace/minimal_impl/target.cpp -o "$target"

"$target" > /tmp/synthetic_target.out 2>&1 &
pid=$!
trap "kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true" EXIT
sleep 1

raw=/tmp/open-obstack-synthetic.out
err=/tmp/open-obstack-synthetic.err
set +e
"$OBSTACK_BIN" -n "$pid" >"$raw" 2>"$err"
rc=$?
set -e

echo "command=$OBSTACK_BIN -n <synthetic_pid>"
echo "target_pid=$pid"
echo "exit_code=$rc"
echo "obstack_output_bytes=$(wc -c <"$raw")"
echo "obstack_stderr_bytes=$(wc -c <"$err")"
echo "obstack_output_lines=$(wc -l <"$raw")"
if [[ "$rc" -eq 0 && -s "$raw" ]]; then
  echo "status=PASS"
else
  echo "status=FAIL"
fi
echo
echo "target_stdout_sample:"
sed -n "1,20p" /tmp/synthetic_target.out
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
