#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCHEME_DIR"

RPM_URL="http://mirrors.aliyun.com/oceanbase/development-kit/el/8/x86_64/obstack-2.0.4-172024070513.el8.x86_64.rpm"
RPM_SHA256="b3acda83d7a237434f302929553598f1e33930d3ac2953bc611ebf95c48a2a7a"
RPM_PATH="$SCHEME_DIR/.cache/obstack-2.0.4.el8.x86_64.rpm"
EXTRACT_DIR="$SCHEME_DIR/.cache/rpm-el8"
BIN="$EXTRACT_DIR/usr/bin/obstack"

mkdir -p .cache "$EXTRACT_DIR"

if [[ ! -f "$RPM_PATH" ]]; then
  curl -fsSL "$RPM_URL" -o "$RPM_PATH"
fi

actual_sha="$(sha256sum "$RPM_PATH" | awk '{print $1}')"
if [[ "$actual_sha" != "$RPM_SHA256" ]]; then
  echo "sha256 mismatch for $RPM_PATH: $actual_sha expected $RPM_SHA256" >&2
  exit 2
fi

if [[ ! -x "$BIN" ]]; then
  bsdtar -C "$EXTRACT_DIR" -xf "$RPM_PATH"
fi

echo "command=provenance_probe"
echo "package_url=$RPM_URL"
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
