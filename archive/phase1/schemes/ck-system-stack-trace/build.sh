#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARIANT="${CK_VARIANT:-all}"

run_variant() {
  local variant="$1"
  "$SCHEME_DIR/variants/$variant/build.sh"
}

case "$VARIANT" in
  all)
    status=0
    run_variant default || status=$?
    run_variant fp-build || status=$?
    exit "$status"
    ;;
  default|fp-build)
    run_variant "$VARIANT"
    ;;
  *)
    echo "unknown CK_VARIANT: $VARIANT" >&2
    echo "expected: all, default, fp-build" >&2
    exit 1
    ;;
esac
