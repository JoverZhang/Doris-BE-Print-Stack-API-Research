#!/usr/bin/env bash
# Reason: prove the ck-phdr-unwind preflight catches the two expensive failure
# modes before a real Phase 2 build runs.
# Local: cheap shell self-test; no git, no compiler, no ccache mutation.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="${ROOT}/scripts/phase2/check-ck-phdr-unwind.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ck-phdr-preflight.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

write_fixture() {
    local repo="$1"
    mkdir -p "${repo}/be/src/service" "${repo}/thirdparty"
    cat >"${repo}/be/src/service/doris_main.cpp" <<'EOF'
int main() {
    // updatePHDRCache();
    updatePHDRCache();
    if (!doris::BackendOptions::init()) {
        return -1;
    }
    return 0;
}
EOF
    cat >"${repo}/thirdparty/build-thirdparty.sh" <<'EOF'
build_jemalloc_doris() {
    ../configure --enable-prof --enable-prof-libunwind
    if ! grep -qE "result: prof-libunwind +: 1$" config.log; then
        exit 1
    fi
}
EOF
}

expect_pass() {
    local name="$1"
    local repo="$2"
    if ! "$CHECK" "$repo" >/dev/null; then
        echo "selftest: expected pass: ${name}" >&2
        exit 1
    fi
}

expect_fail() {
    local name="$1"
    local repo="$2"
    local pattern="$3"
    local out
    set +e
    out="$("$CHECK" "$repo" 2>&1)"
    local rc=$?
    set -e
    if [[ "$rc" -eq 0 ]]; then
        echo "selftest: expected failure: ${name}" >&2
        exit 1
    fi
    if ! grep -q -- "$pattern" <<<"$out"; then
        echo "selftest: ${name}: output did not contain ${pattern}" >&2
        echo "$out" >&2
        exit 1
    fi
}

repo="${tmp}/good"
write_fixture "$repo"
expect_pass "good fixture" "$repo"

repo="${tmp}/missing-update"
write_fixture "$repo"
sed -i 's|    updatePHDRCache();|    // updatePHDRCache();|' \
    "${repo}/be/src/service/doris_main.cpp"
expect_fail "missing updatePHDRCache" "$repo" "missing active updatePHDRCache"

repo="${tmp}/missing-jemalloc-flag"
write_fixture "$repo"
sed -i 's/ --enable-prof-libunwind//' "${repo}/thirdparty/build-thirdparty.sh"
expect_fail "missing jemalloc flag" "$repo" "missing --enable-prof-libunwind"

echo "ck-phdr-unwind preflight selftest: OK"
