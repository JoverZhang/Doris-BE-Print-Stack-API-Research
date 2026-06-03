#!/usr/bin/env bash
# Reason: one explicit local BE UT entrypoint for Phase 2. The public shape is
# `just phase2-test <suite> <target> <mode> <gtest-filter>`; this script keeps
# branch switching, build mode selection, allocator mode, and targeted filters
# in one place.
# Spec: docs/phase2-test-plan.md.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

usage() {
    cat >&2 <<'EOF'
usage: test.sh <new-ut|full-ut> <base|common|variant> <asan|release|tsan|jemalloc> <gtest-filter>

examples:
  test.sh new-ut fp-walk asan '*NativeStackActionTest.*'
  test.sh full-ut base asan 'BrpcClientCacheTest.invalid'
  test.sh full-ut fp-walk asan '*'
  DORIS_BE_CLEAN=1 DORIS_BE_JOBS=24 test.sh full-ut fp-walk asan '*'
EOF
}

if [[ $# -ne 4 ]]; then
    usage
    exit 2
fi

suite="$1"
target="$2"
mode="$3"
filter="$4"

case "$suite" in
    new-ut | full-ut) ;;
    *)
        echo "error: unknown suite: ${suite}" >&2
        usage
        exit 2
        ;;
esac

valid_target() {
    local candidate="$1"
    local variant
    case "$candidate" in
        base | common) return 0 ;;
    esac
    for variant in $VARIANTS; do
        if [[ "$candidate" == "$variant" ]]; then
            return 0
        fi
    done
    return 1
}

if ! valid_target "$target"; then
    echo "error: unknown target: ${target}" >&2
    usage
    exit 2
fi

case "$mode" in
    asan | release | tsan | jemalloc) ;;
    *)
        echo "error: unknown mode: ${mode}" >&2
        usage
        exit 2
        ;;
esac

clean=0
case "${DORIS_BE_CLEAN:-}" in
    "" | 0 | false | FALSE | no | NO) ;;
    1 | true | TRUE | yes | YES) clean=1 ;;
    *)
        echo "error: DORIS_BE_CLEAN must be 1/true/yes or unset/0/false/no" >&2
        exit 2
        ;;
esac

if [[ -n "${DORIS_BE_JOBS:-}" && ! "${DORIS_BE_JOBS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: DORIS_BE_JOBS must be a positive integer" >&2
    exit 2
fi

jobs_label="doris-default"
run_be_ut_jobs=()
if [[ -n "${DORIS_BE_JOBS:-}" ]]; then
    jobs_label="${DORIS_BE_JOBS}"
    run_be_ut_jobs=(-j "${DORIS_BE_JOBS}")
fi

# 1. Refuse on a dirty tree; a switch would corrupt state.
assert_clean_worktree "$DORIS_REPO"

# 2. Switch to the requested phase2 branch. `base` is valid because bootstrap
# creates phase2/base at DORIS_BASE.
git -C "$DORIS_REPO" switch "phase2/$target"
head="$(git -C "$DORIS_REPO" rev-parse --short=12 HEAD)"

run_with_doris_ut_script() {
    local build_type="$1"
    local clean_label="no"
    local args=(--run --filter="$filter")
    if [[ "$clean" -eq 1 ]]; then
        args+=(--clean)
        clean_label="yes"
    fi
    args+=("${run_be_ut_jobs[@]}")

    echo "phase2-test: suite=${suite} target=${target} branch=phase2/${target} head=${head} mode=${mode} build_type=${build_type} use_jemalloc=OFF jobs=${jobs_label} clean=${clean_label} filter=${filter}"
    cd "$DORIS_REPO"
    BUILD_TYPE_UT="$build_type" ./run-be-ut.sh "${args[@]}"
}

prepend_ld_library_path() {
    local value="${1:?}"
    if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
        export LD_LIBRARY_PATH="${value}:${LD_LIBRARY_PATH}"
    else
        export LD_LIBRARY_PATH="${value}"
    fi
}

jdk_version() {
    local java_cmd="${1:-}"
    local version
    if [[ -z "$java_cmd" ]]; then
        echo "no_java"
        return 1
    fi

    version="$("$java_cmd" -Xms32M -Xmx32M -version 2>&1 | tr '\r' '\n' | grep version | awk '{print $3}')"
    version="${version//\"/}"
    if [[ "$version" =~ ^1\. ]]; then
        echo "$version" | awk -F '.' '{print $2}'
    else
        echo "$version" | awk -F '.' '{print $1}'
    fi
}

setup_java_env() {
    local java_version
    local jvm_arch="amd64"

    echo "JAVA_HOME: ${JAVA_HOME:-}"
    if [[ -z "${JAVA_HOME:-}" ]]; then
        return 1
    fi

    if [[ "$(uname -m)" == "aarch64" ]]; then
        jvm_arch="aarch64"
    fi

    java_version="$(jdk_version "${JAVA_HOME}/bin/java")"
    if [[ "$java_version" -gt 8 && -d "${JAVA_HOME}/lib/server" ]]; then
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

update_submodule() {
    local submodule_path="$1"
    local submodule_name="$2"
    local archive_url="$3"
    local exit_code
    local submodule_commit
    local commit_specific_url

    set +e
    cd "$DORIS_REPO"
    echo "Update ${submodule_name} submodule ..."
    git submodule update --init --recursive "$submodule_path"
    exit_code=$?
    set -e
    if [[ "$exit_code" -ne 0 ]]; then
        submodule_commit="$(git ls-tree HEAD "$submodule_path" | awk '{print $3}')"
        commit_specific_url="$(echo "$archive_url" | sed "s/refs\\/heads/${submodule_commit}/")"
        echo "Update ${submodule_name} submodule failed, start to download and extract ${commit_specific_url}"
        mkdir -p "${DORIS_REPO}/${submodule_path}"
        curl -L "$commit_specific_url" | tar -xz -C "${DORIS_REPO}/${submodule_path}" --strip-components=1
    fi
}

configure_jemalloc_build() {
    local cmake_build_dir="$1"
    local make_program
    local build_azure="ON"
    local glibc_compatibility="${GLIBC_COMPATIBILITY:-ON}"
    local use_libcpp="${USE_LIBCPP:-OFF}"
    local use_avx2="${USE_AVX2:-ON}"
    local arm_march="${ARM_MARCH:-armv8-a+crc}"
    local enable_injection_point="${ENABLE_INJECTION_POINT:-ON}"
    local enable_pch="${ENABLE_PCH:-ON}"

    make_program="$(command -v "${BUILD_SYSTEM}")"
    if [[ "$(echo "${DISABLE_BUILD_AZURE:-OFF}" | tr '[:lower:]' '[:upper:]')" == "ON" ]]; then
        build_azure="OFF"
    fi

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
        "${DORIS_REPO}/be"
}

prepare_jemalloc_runtime() {
    local cmake_build_dir="$1"
    local test_binary_dir="${cmake_build_dir}/test"
    local conf_dir="${test_binary_dir}/conf"
    local gtest_output_dir="${cmake_build_dir}/gtest_output"
    local ut_tmp_dir="${DORIS_REPO}/ut_dir"
    local lib_dir="${test_binary_dir}/lib"
    local java_version
    local cur_date
    local log_path
    local common_opts
    local jdbc_opts
    local final_java_opt
    local jar

    export DORIS_TEST_BINARY_DIR="$test_binary_dir"
    rm -rf "$conf_dir"
    mkdir -p "$conf_dir"
    cp "${DORIS_REPO}/conf/be.conf" "$conf_dir/"

    export TERM="xterm"
    export UDF_RUNTIME_DIR="${test_binary_dir}/lib/udf-runtime"
    export LOG_DIR="${test_binary_dir}/log"
    mkdir -p "$LOG_DIR" "$UDF_RUNTIME_DIR"
    rm -f "${UDF_RUNTIME_DIR}"/* 2>/dev/null || true

    while read -r variable; do
        eval "export ${variable}"
    done < <(sed 's/[[:space:]]*\(=\)[[:space:]]*/\1/' "${conf_dir}/be.conf" | grep -E "^[[:upper:]]([[:upper:]]|_|[[:digit:]])*=")

    find "$cmake_build_dir" -name "*gcda" -delete
    setup_java_env || true

    rm -rf "$gtest_output_dir"
    mkdir -p "$gtest_output_dir"

    mkdir -p "${test_binary_dir}/util"
    rm -rf "${test_binary_dir}/util/test_data"
    cp -r "${DORIS_REPO}/be/test/util/test_data" "${test_binary_dir}/util/"

    rm -rf "$ut_tmp_dir"
    mkdir -p "$ut_tmp_dir"
    touch "${ut_tmp_dir}/tmp_file"

    rm -rf "$lib_dir"
    mkdir -p "$lib_dir"
    if [[ -d "${DORIS_THIRDPARTY}/installed/lib/hadoop_hdfs/" ]]; then
        cp -r "${DORIS_THIRDPARTY}/installed/lib/hadoop_hdfs/" "$lib_dir"
    fi
    if [[ -f "${DORIS_REPO}/output/be/lib/java-udf-jar-with-dependencies.jar" ]]; then
        cp "${DORIS_REPO}/output/be/lib/java-udf-jar-with-dependencies.jar" "$lib_dir/"
    fi

    export DORIS_CLASSPATH="${DORIS_CLASSPATH:-}"
    for jar in "$lib_dir"/*.jar; do
        [[ -e "$jar" ]] || continue
        if [[ -z "$DORIS_CLASSPATH" ]]; then
            DORIS_CLASSPATH="$jar"
        else
            DORIS_CLASSPATH="${jar}:${DORIS_CLASSPATH}"
        fi
    done

    if [[ -d "${lib_dir}/hadoop_hdfs/" ]]; then
        for jar in "${lib_dir}/hadoop_hdfs/common"/*.jar "${lib_dir}/hadoop_hdfs/common/lib"/*.jar "${lib_dir}/hadoop_hdfs/hdfs"/*.jar "${lib_dir}/hadoop_hdfs/hdfs/lib"/*.jar; do
            [[ -e "$jar" ]] || continue
            DORIS_CLASSPATH="${jar}:${DORIS_CLASSPATH}"
        done
    fi

    export CLASSPATH="$DORIS_CLASSPATH"
    export DORIS_CLASSPATH="-Djava.class.path=${DORIS_CLASSPATH}"

    java_version="$(jdk_version "${JAVA_HOME}/bin/java")"
    cur_date="$(date +%Y%m%d-%H%M%S)"
    log_path="-DlogPath=${test_binary_dir}/log/jni.log"
    common_opts="-Dsun.java.command=DorisBETEST -XX:-CriticalJNINatives"
    jdbc_opts="-DJDBC_MIN_POOL=1 -DJDBC_MAX_POOL=100 -DJDBC_MAX_IDLE_TIME=300000"

    if [[ "$java_version" -gt 8 ]]; then
        final_java_opt="${JAVA_OPTS:-}"
        if [[ -z "$final_java_opt" ]]; then
            final_java_opt="-Xmx1024m ${log_path} -Xloggc:${test_binary_dir}/log/be.gc.log.${cur_date} ${common_opts} ${jdbc_opts}"
        fi
    else
        final_java_opt="${JAVA_OPTS_FOR_JDK_9:-}"
        if [[ -z "$final_java_opt" ]]; then
            final_java_opt="-Xmx1024m ${log_path} -Xlog:gc:${test_binary_dir}/log/be.gc.log.${cur_date} ${common_opts} ${jdbc_opts}"
        fi
    fi

    if [[ "$(uname -s)" == "Darwin" ]]; then
        local max_fd_limit="-XX:-MaxFDLimit"
        if ! echo "$final_java_opt" | grep "${max_fd_limit/-/\\-}" >/dev/null; then
            final_java_opt="${final_java_opt} ${max_fd_limit}"
        fi
    fi

    export LIBHDFS_OPTS="$final_java_opt"
    export ORC_EXAMPLE_DIR="${DORIS_REPO}/contrib/apache-orc/examples"
    export DORIS_HOME="${test_binary_dir}/"
    export ASAN_OPTIONS=symbolize=1:abort_on_error=1:disable_coredump=0:unmap_shadow_on_exit=1:detect_container_overflow=0:check_malloc_usable_size=0
    export UBSAN_OPTIONS=print_stacktrace=1
    export JAVA_OPTS="-Xmx1024m -DlogPath=${DORIS_HOME}/log/jni.log -Xloggc:${DORIS_HOME}/log/be.gc.log.${cur_date} -Dsun.java.command=DorisBE -XX:-CriticalJNINatives -DJDBC_MIN_POOL=1 -DJDBC_MAX_POOL=100 -DJDBC_MAX_IDLE_TIME=300000"

    if [[ -n "${PHASE2_JEMALLOC_CONF:-}" ]]; then
        export JEMALLOC_CONF="${PHASE2_JEMALLOC_CONF}"
    fi
    if [[ -n "${JEMALLOC_CONF:-}" && -z "${MALLOC_CONF:-}" ]]; then
        export MALLOC_CONF="prof_prefix:,${JEMALLOC_CONF}"
    fi

    JEMALLOC_GTEST_OUTPUT_DIR="$gtest_output_dir"
}

run_with_jemalloc() {
    local build_label="JEMALLOC_RELEASE"
    local cmake_build_dir="${DORIS_REPO}/be/ut_build_${build_label}"
    local parallel
    local jemalloc_jobs_label
    local clean_label="no"
    local gtest_output_dir
    local test_binary
    local file_name

    cd "$DORIS_REPO"
    export ROOT="$DORIS_REPO"
    export DORIS_HOME="$DORIS_REPO"
    # shellcheck disable=1091
    set +u
    . "${DORIS_HOME}/env.sh"
    set -u

    if [[ -z "${DORIS_BE_JOBS:-}" ]]; then
        parallel="$(($(nproc) / 5 + 1))"
        jemalloc_jobs_label="doris-default(${parallel})"
    else
        parallel="${DORIS_BE_JOBS}"
        jemalloc_jobs_label="${parallel}"
    fi

    if [[ "$clean" -eq 1 ]]; then
        clean_label="yes"
        if [[ -d "${DORIS_REPO}/gensrc" ]]; then
            make -C "${DORIS_REPO}/gensrc" clean
        fi
        rm -rf "$cmake_build_dir" "${DORIS_REPO}/be/output"
    fi

    echo "phase2-test: suite=${suite} target=${target} branch=phase2/${target} head=${head} mode=jemalloc build_type=RELEASE use_jemalloc=ON build_dir=be/ut_build_${build_label} jobs=${jemalloc_jobs_label} clean=${clean_label} filter=${filter}"

    update_submodule "contrib/apache-orc" "apache-orc" "https://github.com/apache/doris-thirdparty/archive/refs/heads/orc.tar.gz"
    update_submodule "contrib/clucene" "clucene" "https://github.com/apache/doris-thirdparty/archive/refs/heads/clucene.tar.gz"
    configure_jemalloc_build "$cmake_build_dir"
    "${CMAKE_CMD}" --build "$cmake_build_dir" --target doris_be_test --parallel "$parallel"

    cd "$DORIS_REPO"
    prepare_jemalloc_runtime "$cmake_build_dir"
    gtest_output_dir="$JEMALLOC_GTEST_OUTPUT_DIR"
    test_binary="${DORIS_TEST_BINARY_DIR}/doris_be_test"
    file_name="${test_binary##*/}"
    if [[ ! -x "$test_binary" ]]; then
        echo "error: unit test binary not found: ${test_binary}" >&2
        exit 1
    fi

    "$test_binary" \
        --gtest_output="xml:${gtest_output_dir}/${file_name}.xml" \
        --gtest_print_time=true \
        --gtest_filter="$filter"

    echo "=== Finished. Gtest output: ${gtest_output_dir}"
}

case "$mode" in
    asan) run_with_doris_ut_script ASAN ;;
    release) run_with_doris_ut_script RELEASE ;;
    tsan) run_with_doris_ut_script TSAN ;;
    jemalloc) run_with_jemalloc ;;
esac
