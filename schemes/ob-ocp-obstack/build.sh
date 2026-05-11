#!/usr/bin/env bash
set -euo pipefail

SCHEME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCHEME_DIR"

source "$SCHEME_DIR/helpers/prepare_obstack.sh"
ocp_obstack_prepare
