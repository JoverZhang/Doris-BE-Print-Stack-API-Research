#!/usr/bin/env bash
set -euo pipefail

repo_root() {
  git rev-parse --show-toplevel
}

log() {
  printf '[%s] %s\n' "$(date -Is)" "$*" >&2
}

ensure_dir() {
  mkdir -p "$1"
}

