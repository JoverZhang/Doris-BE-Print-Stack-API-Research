#!/usr/bin/env bash
# Reason: regenerate repos/source/doris-master/be/build_Release/compile_commands.json
# with HOST paths so clangd on the host can resolve them. The previous build
# ran with a different mount layout (/workspace/project/...), so its
# compile_commands was unusable from the host.
#
# Runs cmake configure only (OUTPUT_BE_BINARY=0 skips ninja). The existing
# build artifacts under be/build_Release/ are kept; only the stale CMakeCache
# is wiped so cmake re-configures cleanly against the new mount paths.
#
# Local: must be called from inside scripts/in-container — uses the Doris
# build-env image and sees DORIS_THIRDPARTY=/var/local/thirdparty.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DORIS="${ROOT}/repos/source/doris-master"
BUILD_DIR="${DORIS}/be/build_Release"

if [[ ! -d "${DORIS}" ]]; then
  echo "skip: ${DORIS} not present" >&2
  exit 0
fi

# Wipe just the cache + CMakeFiles. Keep object files / generated headers
# so a later ninja invocation is incremental.
rm -f  "${BUILD_DIR}/CMakeCache.txt"
rm -rf "${BUILD_DIR}/CMakeFiles"

cd "${DORIS}"
OUTPUT_BE_BINARY=0 ./build.sh --be
