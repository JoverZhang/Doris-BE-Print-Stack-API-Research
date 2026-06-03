#!/usr/bin/env bash
# Reason: run the selected fp-walk collector under Doris's production allocator
# shape. run-be-ut.sh hard-codes USE_JEMALLOC=OFF, so this local harness keeps a
# separate Release build dir with USE_JEMALLOC=ON and runs the same filtered UT.
# Spec: docs/phase2-test-plan.md "jemalloc Release smoke".
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

variant="${1:?usage: test-jemalloc.sh <variant>}"
if [[ "${variant}" != "fp-walk" ]]; then
    echo "error: phase2-test-jemalloc currently supports fp-walk only" >&2
    exit 2
fi

# 1. Refuse on a dirty Doris tree; a switch would corrupt state.
assert_clean_worktree "$DORIS_REPO"

# 2. Switch to the selected variant branch.
git -C "$DORIS_REPO" switch "phase2/$variant"

# 3. Source Doris's build environment. The container wrapper supplies a
# persistent CCACHE_DIR; env.sh contributes the compiler launcher flags.
cd "$DORIS_REPO"
export ROOT="$DORIS_REPO"
export DORIS_HOME="$DORIS_REPO"
# shellcheck disable=1091
set +u
. "${DORIS_HOME}/env.sh"
set -u

if [[ -z "${PHASE2_UT_JOBS:-}" ]]; then
    parallel="$(($(nproc) / 5 + 1))"
    jobs_label="doris-default(${parallel})"
else
    parallel="${PHASE2_UT_JOBS}"
    jobs_label="${parallel}"
fi

build_label="JEMALLOC_RELEASE"
cmake_build_dir="${DORIS_HOME}/be/ut_build_${build_label}"
make_program="$(command -v "${BUILD_SYSTEM}")"
build_azure="ON"
if [[ "$(echo "${DISABLE_BUILD_AZURE:-OFF}" | tr '[:lower:]' '[:upper:]')" == "ON" ]]; then
    build_azure="OFF"
fi
glibc_compatibility="${GLIBC_COMPATIBILITY:-ON}"
use_libcpp="${USE_LIBCPP:-OFF}"
use_avx2="${USE_AVX2:-ON}"
arm_march="${ARM_MARCH:-armv8-a+crc}"
enable_injection_point="${ENABLE_INJECTION_POINT:-ON}"
enable_pch="${ENABLE_PCH:-ON}"

echo "phase2-test-jemalloc: variant=${variant} build_type=RELEASE use_jemalloc=ON build_dir=be/ut_build_${build_label} jobs=${jobs_label}"

mkdir -p "$cmake_build_dir"
cd "$cmake_build_dir"
"${CMAKE_CMD}" -G "${GENERATOR}" \
    -DCMAKE_MAKE_PROGRAM="${make_program}" \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DCMAKE_BUILD_TYPE=RELEASE \
    -DMAKE_TEST=ON \
    -DGLIBC_COMPATIBILITY="${glibc_compatibility}" \
    -DUSE_LIBCPP="${use_libcpp}" \
    -DBUILD_META_TOOL=OFF \
    -DBUILD_FILE_CACHE_MICROBENCH_TOOL=OFF \
    -DUSE_UNWIND=ON \
    -DUSE_JEMALLOC=ON \
    -DUSE_AVX2="${use_avx2}" \
    -DARM_MARCH="${arm_march}" \
    -DEXTRA_CXX_FLAGS="${EXTRA_CXX_FLAGS:-}" \
    -DENABLE_CLANG_COVERAGE=OFF \
    -DENABLE_INJECTION_POINT="${enable_injection_point}" \
    ${CMAKE_USE_CCACHE_CXX:+${CMAKE_USE_CCACHE_CXX}} \
    ${CMAKE_USE_CCACHE_C:+${CMAKE_USE_CCACHE_C}} \
    -DENABLE_PCH="${enable_pch}" \
    -DDORIS_JAVA_HOME="${JAVA_HOME}" \
    -DBUILD_AZURE="${build_azure}" \
    -DWITH_TDE_DIR="${WITH_TDE_DIR:-}" \
    "${DORIS_HOME}/be"
"${CMAKE_CMD}" --build "$cmake_build_dir" --target doris_be_test --parallel "$parallel"

# 4. Prepare the runtime environment the same way run-be-ut.sh does for the
# single test binary. Keep JEMALLOC_CONF/MALLOC_CONF explicit so this smoke
# follows the normal start_be.sh allocator environment.
cd "$DORIS_HOME"
export DORIS_TEST_BINARY_DIR="${cmake_build_dir}/test"
conf_dir="${DORIS_TEST_BINARY_DIR}/conf"
rm -rf "$conf_dir"
mkdir -p "$conf_dir"
cp "${DORIS_HOME}/conf/be.conf" "$conf_dir/"

export TERM="xterm"
export UDF_RUNTIME_DIR="${DORIS_TEST_BINARY_DIR}/lib/udf-runtime"
export LOG_DIR="${DORIS_TEST_BINARY_DIR}/log"
mkdir -p "$LOG_DIR" "$UDF_RUNTIME_DIR"
rm -f "${UDF_RUNTIME_DIR}"/* 2>/dev/null || true

prepend_ld_library_path() {
    local value="${1:?}"
    if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
        export LD_LIBRARY_PATH="${value}:${LD_LIBRARY_PATH}"
    else
        export LD_LIBRARY_PATH="${value}"
    fi
}

setup_java_runtime_path() {
    if [[ -z "${JAVA_HOME:-}" ]]; then
        return 0
    fi

    local jvm_arch="amd64"
    if [[ "$(uname -m)" == "aarch64" ]]; then
        jvm_arch="aarch64"
    fi

    if [[ -d "${JAVA_HOME}/lib/server" ]]; then
        prepend_ld_library_path "${JAVA_HOME}/lib/server:${JAVA_HOME}/lib"
    elif [[ -d "${JAVA_HOME}/jre/lib/${jvm_arch}/server" ]]; then
        prepend_ld_library_path "${JAVA_HOME}/jre/lib/${jvm_arch}/server:${JAVA_HOME}/jre/lib/${jvm_arch}"
    else
        prepend_ld_library_path "${JAVA_HOME}/lib/${jvm_arch}/server:${JAVA_HOME}/lib/${jvm_arch}"
    fi

    if [[ "$(uname -s)" == "Darwin" ]]; then
        export DYLD_LIBRARY_PATH="${LD_LIBRARY_PATH}:${DYLD_LIBRARY_PATH:-}"
    fi
}

while read -r variable; do
    eval "export ${variable}"
done < <(sed 's/[[:space:]]*\(=\)[[:space:]]*/\1/' "${conf_dir}/be.conf" | grep -E "^[[:upper:]]([[:upper:]]|_|[[:digit:]])*=")

setup_java_runtime_path

if [[ -n "${PHASE2_JEMALLOC_CONF:-}" ]]; then
    export JEMALLOC_CONF="${PHASE2_JEMALLOC_CONF}"
fi
if [[ -n "${JEMALLOC_CONF:-}" && -z "${MALLOC_CONF:-}" ]]; then
    export MALLOC_CONF="prof_prefix:,${JEMALLOC_CONF}"
fi

gtest_output_dir="${cmake_build_dir}/gtest_output"
rm -rf "$gtest_output_dir"
mkdir -p "$gtest_output_dir"

mkdir -p "${DORIS_TEST_BINARY_DIR}/util"
rm -rf "${DORIS_TEST_BINARY_DIR}/util/test_data"
cp -r "${DORIS_HOME}/be/test/util/test_data" "${DORIS_TEST_BINARY_DIR}/util/"

export DORIS_HOME="${DORIS_TEST_BINARY_DIR}/"
test_binary="${DORIS_TEST_BINARY_DIR}/doris_be_test"
if [[ ! -x "$test_binary" ]]; then
    echo "error: unit test binary not found: $test_binary" >&2
    exit 1
fi

"$test_binary" \
    --gtest_output="xml:${gtest_output_dir}/doris_be_test.xml" \
    --gtest_print_time=true \
    --gtest_filter="*NativeStackActionTest.*"

echo "=== Finished. Gtest output: ${gtest_output_dir}"
