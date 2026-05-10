#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCHEME_DIR"

SOURCE_DIR="${OBSTACK_SOURCE_DIR:-$SCHEME_DIR/.cache/obstack-source}"
COMMIT="${OBSTACK_COMMIT:-d91edd6d882a33b69164f8d3e809092408da3a33}"

mkdir -p commands .cache

if [[ ! -d "$SOURCE_DIR/.git" ]]; then
  git clone --depth 1 --filter=blob:none https://github.com/oceanbase/obstack.git "$SOURCE_DIR"
fi

actual_commit="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
if [[ "$actual_commit" != "$COMMIT" ]]; then
  echo "unexpected obstack commit: $actual_commit, expected $COMMIT" >&2
  exit 2
fi

if [[ "${OBSTACK_FULL_SOURCE_BUILD:-0}" != "1" ]]; then
  ./commands/source_build_probe.sh > commands/source_build_probe.out
  echo "BLOCKED: full open obstack source build is disabled by default because the current host probe is blocked." >&2
  exit 2
fi

(
  cd "$SOURCE_DIR"
  ./build.sh release
)

for candidate in "$SOURCE_DIR"/build_release/src/obstack "$SOURCE_DIR"/build*/src/obstack; do
  if [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    exit 0
  fi
done

echo "built obstack binary was not found under $SOURCE_DIR/build*/src/obstack" >&2
exit 2
