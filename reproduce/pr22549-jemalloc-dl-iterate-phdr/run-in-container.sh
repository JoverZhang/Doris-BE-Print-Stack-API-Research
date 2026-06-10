#!/usr/bin/env bash
# Reason: create a deterministic feedback loop for apache/doris#22549. The
# loop applies the old PHDR-cache override, rebuilds only the affected BE
# pieces, then interrupts gdb after jemalloc deadlocks before main().
# Local: reproduce/pr22549-jemalloc-dl-iterate-phdr.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "${script_dir}/../.." && pwd)}"
source "${PROJECT_ROOT}/scripts/phase2/_common.sh"

patch_file="${script_dir}/repro.patch"
expected_file="${script_dir}/expected-key-frames.txt"
out_root="${script_dir}/.tmp"
run_id="$(date -u +%Y%m%dT%H%M%SZ)"
out_dir="${out_root}/${run_id}"
build_dir="${DORIS_REPO}/be/build_Release"
binary="${build_dir}/src/service/doris_be"
ninja="${NINJA:-/var/local/ldb-toolchain/bin/ninja}"
gdb="${GDB:-/var/local/ldb-toolchain/bin/gdb}"
if [[ -x /var/local/ldb-toolchain/bin/nm ]]; then
    nm_tool=/var/local/ldb-toolchain/bin/nm
else
    nm_tool=nm
fi
jobs="${DORIS_BE_JOBS:-31}"
timeout_s="${REPRO_TIMEOUT:-8}"
control_timeout_s="${REPRO_CONTROL_TIMEOUT:-8}"
stash_created=0
stash_ref=
original_branch=
original_commit=

mkdir -p "$out_dir"
ln -sfnT "$run_id" "${out_root}/latest"

fail_with_log() {
    local message="$1"
    local log_file="${2:-}"
    echo "error: ${message}" >&2
    if [[ -n "$log_file" && -f "$log_file" ]]; then
        echo "---- tail ${log_file} ----" >&2
        tail -n 80 "$log_file" >&2 || true
    fi
    exit 1
}

clean_doris_worktree() {
    git -C "$DORIS_REPO" reset --hard >/dev/null
    git -C "$DORIS_REPO" clean -fd \
        -e 'be/ut_build*/' \
        -e 'be/ut_build*' \
        >/dev/null
}

restore_original_ref() {
    if [[ -n "$original_branch" ]]; then
        git -C "$DORIS_REPO" switch "$original_branch" >/dev/null
    else
        git -C "$DORIS_REPO" switch --detach "$original_commit" >/dev/null
    fi
}

source_doris_env() {
    local log_file="$1"
    export DORIS_HOME="$DORIS_REPO"
    export ROOT="$DORIS_REPO"

    set +e
    set +u
    # shellcheck source=/dev/null
    source "${DORIS_REPO}/env.sh" >>"$log_file" 2>&1
    local rc=$?
    set -e
    set -u
    set -o pipefail
    return "$rc"
}

build_and_link() {
    local log_file="$1"
    : >"$log_file"

    [[ -f "${build_dir}/build.ninja" ]] || \
        fail_with_log "missing ${build_dir}/build.ninja; create the Release BE build dir before running this reproducer"

    source_doris_env "$log_file" || fail_with_log "failed to source Doris env.sh" "$log_file"

    "$ninja" -C "$build_dir" \
        src/common/libCommon.a \
        src/service/CMakeFiles/doris_be.dir/doris_main.cpp.o \
        -j "$jobs" >>"$log_file" 2>&1 || \
        fail_with_log "failed to rebuild changed BE objects" "$log_file"

    local link_cmd
    link_cmd="$("$ninja" -C "$build_dir" -t commands src/service/doris_be 2>>"$log_file" \
        | grep ' -o src/service/doris_be ' \
        | tail -n 1)" || \
        fail_with_log "failed to extract doris_be link command" "$log_file"
    [[ -n "$link_cmd" ]] || fail_with_log "empty doris_be link command" "$log_file"

    (cd "$build_dir" && eval "$link_cmd") >>"$log_file" 2>&1 || \
        fail_with_log "failed to relink doris_be" "$log_file"
}

record_symbols() {
    local output_file="$1"
    {
        echo "## phdr_cache.cpp.o"
        "$nm_tool" -an "${build_dir}/src/common/CMakeFiles/Common.dir/phdr_cache.cpp.o" \
            | grep -E 'dl_iterate_phdr|updatePHDRCache|hasPHDRCache' || true
        echo "## doris_main.cpp.o"
        "$nm_tool" -an "${build_dir}/src/service/CMakeFiles/doris_be.dir/doris_main.cpp.o" \
            | grep -E 'dl_iterate_phdr|updatePHDRCache|hasPHDRCache' || true
        echo "## libCommon.a"
        "$nm_tool" -an "${build_dir}/src/common/libCommon.a" \
            | grep -E 'dl_iterate_phdr|updatePHDRCache|hasPHDRCache' || true
        echo "## doris_be"
        "$nm_tool" -an "$binary" \
            | grep -E 'dl_iterate_phdr|updatePHDRCache|hasPHDRCache' || true
    } >"$output_file"
}

normalize_stack_excerpt() {
    local stack_file="$1"
    awk '
        /^Thread 1 \(Thread / { in_stack = 1; print; next }
        in_stack && /^#[0-9]+/ { print; next }
        in_stack { exit }
    ' "$stack_file" \
        | sed -E \
            -e 's/0x[0-9a-f]+/<addr>/g' \
            -e 's/LWP [0-9]+/LWP <lwp>/g'
}

assert_expected_stack() {
    local stack_file="$1"
    local normalized_file="${out_dir}/normalized-stack.txt"
    local diff_file="${out_dir}/expected-stack.diff"

    normalize_stack_excerpt "$stack_file" >"$normalized_file"
    if ! diff -u "$expected_file" "$normalized_file" >"$diff_file"; then
        echo "error: normalized stack did not match ${expected_file}" >&2
        cat "$diff_file" >&2
        exit 1
    fi
}

restore_clean_build_best_effort() {
    local log_file="${out_dir}/cleanup-rebuild.log"
    : >"$log_file"
    if [[ ! -f "${build_dir}/build.ninja" ]]; then
        echo "cleanup: missing ${build_dir}/build.ninja; skipped clean relink" >>"$log_file"
        return 0
    fi
    source_doris_env "$log_file" || return 1
    "$ninja" -C "$build_dir" \
        src/common/libCommon.a \
        src/service/CMakeFiles/doris_be.dir/doris_main.cpp.o \
        -j "$jobs" >>"$log_file" 2>&1 || return 1
    local link_cmd
    link_cmd="$("$ninja" -C "$build_dir" -t commands src/service/doris_be 2>>"$log_file" \
        | grep ' -o src/service/doris_be ' \
        | tail -n 1)" || return 1
    [[ -n "$link_cmd" ]] || return 1
    (cd "$build_dir" && eval "$link_cmd") >>"$log_file" 2>&1
}

cleanup() {
    local rc=$?
    set +e

    clean_doris_worktree
    restore_original_ref
    clean_doris_worktree
    restore_clean_build_best_effort
    local rebuild_rc=$?
    if [[ $rebuild_rc -ne 0 ]]; then
        echo "warning: cleanup could not relink the original clean doris_be; see ${out_dir}/cleanup-rebuild.log" >&2
        [[ $rc -eq 0 ]] && rc=$rebuild_rc
    fi

    if [[ "$stash_created" -eq 1 ]]; then
        git -C "$DORIS_REPO" stash pop --index "$stash_ref" >>"${out_dir}/stash-pop.log" 2>&1
        local pop_rc=$?
        if [[ $pop_rc -ne 0 ]]; then
            echo "error: failed to restore saved Doris worktree state; see ${out_dir}/stash-pop.log" >&2
            rc=$pop_rc
        fi
    fi

    exit "$rc"
}
trap cleanup EXIT

original_branch="$(git -C "$DORIS_REPO" symbolic-ref --quiet --short HEAD || true)"
original_commit="$(git -C "$DORIS_REPO" rev-parse HEAD)"

if [[ -n "$(git -C "$DORIS_REPO" status --porcelain --untracked-files=normal)" ]]; then
    echo "saving dirty Doris worktree state with git stash"
    git -C "$DORIS_REPO" stash push -u -m "reproduce-pr22549-${run_id}" >"${out_dir}/stash-push.log" 2>&1 || \
        fail_with_log "failed to stash dirty Doris worktree state" "${out_dir}/stash-push.log"
    stash_created=1
    stash_ref="stash@{0}"
fi

clean_doris_worktree
git -C "$DORIS_REPO" switch --detach "$DORIS_BASE" >/dev/null
git -C "$DORIS_REPO" apply --unidiff-zero "$patch_file"

echo "building doris_be with PHDR-cache override, jobs=${jobs}"
build_and_link "${out_dir}/build.log"
record_symbols "${out_dir}/patched-symbols.txt"

if ! grep -q ' T dl_iterate_phdr$' "${out_dir}/patched-symbols.txt"; then
    fail_with_log "rebuilt doris_be does not export dl_iterate_phdr" "${out_dir}/patched-symbols.txt"
fi

run_gdb_case() {
    local label="$1"
    local jemalloc_conf="$2"
    local timeout_value="$3"
    local output_file="$4"
    local log_dir="${out_dir}/be-log-${label}"

    mkdir -p "$log_dir"
    rm -f "${DORIS_REPO}/bin/be.pid"

    export DORIS_HOME="$DORIS_REPO"
    export PID_DIR="${DORIS_REPO}/bin"
    export LOG_DIR="$log_dir"
    export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/jdk-17.0.2}"
    export LD_LIBRARY_PATH="${JAVA_HOME}/lib/server:${JAVA_HOME}/lib:${LD_LIBRARY_PATH:-}"
    export JEMALLOC_CONF="$jemalloc_conf"
    export MALLOC_CONF="$JEMALLOC_CONF"

    set +e
    timeout -s INT "${timeout_value}s" "$gdb" -q -batch \
        -ex "set pagination off" \
        -ex "break main" \
        -ex run \
        -ex "thread apply all bt" \
        -ex quit \
        --args "$binary" >"$output_file" 2>&1
    local gdb_rc=$?
    set -e
    echo "$gdb_rc" >"${output_file}.rc"
}

prof_stack="${out_dir}/gdb-stack.txt"
control_stack="${out_dir}/control-prof-false.txt"

echo "running gdb repro, timeout=${timeout_s}s"
run_gdb_case "prof-active" \
    "prof:true,prof_active:true,lg_prof_interval:20,prof_prefix:${out_dir}/jemalloc_heap_profile" \
    "$timeout_s" \
    "$prof_stack"

grep -n -E 'malloc_mutex_lock_final|malloc_init_hard|jecalloc|_dlerror_run|dlsym|getOriginalDLIteratePHDR|dl_iterate_phdr|_Unwind_Backtrace|je_prof_boot2|AllocateHeap|_dl_init_internal|_dl_start_user' \
    "$prof_stack" >"${out_dir}/key-stack.txt" || true

prof_rc="$(cat "${prof_stack}.rc")"
[[ "$prof_rc" == "124" ]] || fail_with_log "expected gdb timeout rc=124, got rc=${prof_rc}" "$prof_stack"
assert_expected_stack "$prof_stack"
if grep -q 'Breakpoint 1, main' "$prof_stack"; then
    fail_with_log "unexpectedly reached main with jemalloc profiling active" "$prof_stack"
fi

echo "running control gdb case with prof:false"
run_gdb_case "prof-false" \
    "prof:false" \
    "$control_timeout_s" \
    "$control_stack"
grep -q 'Breakpoint 1, main' "$control_stack" || \
    fail_with_log "control case did not reach main with prof:false" "$control_stack"

echo "PASS: reproduced pre-main jemalloc/dl_iterate_phdr deadlock"
echo "stack: ${prof_stack}"
echo "key frames:"
sed -n '1,80p' "${out_dir}/key-stack.txt"
