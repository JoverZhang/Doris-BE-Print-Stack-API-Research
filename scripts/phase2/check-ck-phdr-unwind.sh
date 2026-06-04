#!/usr/bin/env bash
# Reason: ck-phdr-unwind has two non-negotiable setup hooks that normal BE
# gtests do not prove. The test runner itself calls `updatePHDRCache()`, so a
# green `PrintStackActionTest` would not catch a missing `doris_main.cpp`
# startup hook. This preflight fails before any jemalloc rebuild or BE compile.
# Local: called by Phase 2 bootstrap, verify, and test flows.
set -euo pipefail

DORIS_REPO="${1:-${DORIS_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../repos/source/doris-master" && pwd)}}"

main_cpp="${DORIS_REPO}/be/src/service/doris_main.cpp"
thirdparty_sh="${DORIS_REPO}/thirdparty/build-thirdparty.sh"

fail() {
    echo "ck-phdr-unwind preflight: $*" >&2
    exit 1
}

[[ -f "$main_cpp" ]] || fail "missing ${main_cpp}"
[[ -f "$thirdparty_sh" ]] || fail "missing ${thirdparty_sh}"

# 1. `updatePHDRCache()` must be an active call before BackendOptions::init.
#    Line comments are stripped so the historical commented-out call does not
#    satisfy the check.
if ! awk '
function uncommented(line) {
    sub(/\/\/.*/, "", line)
    return line
}
{
    code = uncommented($0)
    if (!update_line && code ~ /updatePHDRCache[[:space:]]*\([[:space:]]*\)[[:space:]]*;/) {
        update_line = NR
    }
    if (!backend_line && code ~ /BackendOptions::init[[:space:]]*\(/) {
        backend_line = NR
    }
}
END {
    if (!update_line) {
        print "missing active updatePHDRCache() call in be/src/service/doris_main.cpp" > "/dev/stderr"
        exit 10
    }
    if (!backend_line) {
        print "missing BackendOptions::init() anchor in be/src/service/doris_main.cpp" > "/dev/stderr"
        exit 11
    }
    if (update_line > backend_line) {
        printf "updatePHDRCache() line %d must precede BackendOptions::init() line %d\n", update_line, backend_line > "/dev/stderr"
        exit 12
    }
}
' "$main_cpp"; then
    fail "invalid PHDR cache startup hook"
fi

# 2. jemalloc must request the libunwind profiler and fail on silent fallback.
grep -q -- "--enable-prof-libunwind" "$thirdparty_sh" || \
    fail "missing --enable-prof-libunwind in thirdparty/build-thirdparty.sh"

grep -qE "prof-libunwind.*: 1" "$thirdparty_sh" || \
    fail "missing prof-libunwind config.log verification in thirdparty/build-thirdparty.sh"

echo "ck-phdr-unwind preflight: OK"
