#!/usr/bin/env bash
set -euo pipefail

OCP_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OCP_SCHEME_DIR="$(cd "${OCP_HELPER_DIR}/.." && pwd)"
OCP_OBSTACK_RPM_URL="http://mirrors.aliyun.com/oceanbase/development-kit/el/8/x86_64/obstack-2.0.4-172024070513.el8.x86_64.rpm"
OCP_OBSTACK_RPM_SHA256="b3acda83d7a237434f302929553598f1e33930d3ac2953bc611ebf95c48a2a7a"
OCP_OBSTACK_RPM_PATH="${OCP_SCHEME_DIR}/.cache/obstack-2.0.4.el8.x86_64.rpm"
OCP_OBSTACK_EXTRACT_DIR="${OCP_SCHEME_DIR}/.cache/rpm-el8"
OCP_OBSTACK_BIN="${OCP_OBSTACK_EXTRACT_DIR}/usr/bin/obstack"

ocp_obstack_prepare() {
  mkdir -p "${OCP_SCHEME_DIR}/.cache" "$OCP_OBSTACK_EXTRACT_DIR"

  if [[ ! -f "$OCP_OBSTACK_RPM_PATH" ]]; then
    curl -fsSL "$OCP_OBSTACK_RPM_URL" -o "$OCP_OBSTACK_RPM_PATH"
  fi

  local actual_sha
  actual_sha="$(sha256sum "$OCP_OBSTACK_RPM_PATH" | awk '{print $1}')"
  if [[ "$actual_sha" != "$OCP_OBSTACK_RPM_SHA256" ]]; then
    echo "sha256 mismatch for $OCP_OBSTACK_RPM_PATH: $actual_sha expected $OCP_OBSTACK_RPM_SHA256" >&2
    exit 2
  fi

  if [[ ! -x "$OCP_OBSTACK_BIN" ]]; then
    bsdtar -C "$OCP_OBSTACK_EXTRACT_DIR" -xf "$OCP_OBSTACK_RPM_PATH"
  fi

  test -x "$OCP_OBSTACK_BIN"
  printf '%s\n' "$OCP_OBSTACK_BIN"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  ocp_obstack_prepare
fi
