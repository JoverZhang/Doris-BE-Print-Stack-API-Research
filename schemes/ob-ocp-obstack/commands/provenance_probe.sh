#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCHEME_DIR"

source "$SCHEME_DIR/helpers/prepare_obstack.sh"
BIN="$(ocp_obstack_prepare)"
actual_sha="$(sha256sum "$OCP_OBSTACK_RPM_PATH" | awk '{print $1}')"

echo "command=provenance_probe"
echo "package_url=$OCP_OBSTACK_RPM_URL"
echo "rpm_sha256=$actual_sha"
echo "binary_sha256=$(sha256sum "$BIN" | awk '{print $1}')"
echo "binary_file=$(file "$BIN" | sed "s#$SCHEME_DIR#<scheme-dir>#g")"
echo
echo "version:"
"$BIN" --version
echo
echo "help_relevant:"
"$BIN" --help 2>&1 | sed -n '1,24p' || true
echo
echo "strings_relevant:"
strings -a "$BIN" | grep -E '/proc/%d/task/|PTRACE_ATTACH|PTRACE_DETACH|_UPT_|unw_' | sort -u | sed -n '1,24p' || true
