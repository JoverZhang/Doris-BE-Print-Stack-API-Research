#!/usr/bin/env bash
# Reason: build and run the standalone PR 22549/glibc dlerror matrix locally.
# Local: reproduce/pr22549-jemalloc-minimal.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out_root="${script_dir}/.tmp"
run_id="$(date -u +%Y%m%dT%H%M%SZ)"
out_dir="${out_root}/${run_id}"
gdb="${GDB:-gdb}"
timeout_s="${REPRO_TIMEOUT:-8}"
matrix_file="${out_dir}/matrix.tsv"

mkdir -p "$out_dir"
ln -sfnT "$run_id" "${out_root}/latest"

fail_with_log() {
    local message="$1"
    local log_file="${2:-}"
    echo "error: ${message}" >&2
    if [[ -n "$log_file" && -f "$log_file" ]]; then
        echo "---- tail ${log_file} ----" >&2
        tail -n 100 "$log_file" >&2 || true
    fi
    exit 1
}

glibc_lib_dir() {
    local variant="$1"
    local install_dir="${out_root}/glibc-install/${variant}"

    if [[ -x "${install_dir}/lib/ld-linux-x86-64.so.2" ]]; then
        echo "${install_dir}/lib"
        return
    fi
    if [[ -x "${install_dir}/lib64/ld-linux-x86-64.so.2" ]]; then
        echo "${install_dir}/lib64"
        return
    fi
    fail_with_log "cannot find glibc loader for variant=${variant}"
}

malloc_conf() {
    local profiling="$1" raw_dir="$2"

    if [[ "$profiling" == "on" ]]; then
        echo "prof:true,prof_active:true,lg_prof_interval:20,prof_prefix:${raw_dir}/jemalloc_heap_profile"
    else
        echo "prof:false"
    fi
}

run_process() {
    local binary="$1" profiling="$2" raw_dir="$3"
    local conf gdb_log

    conf="$(malloc_conf "$profiling" "$raw_dir")"
    gdb_log="${raw_dir}/gdb-run.txt"

    set +e
    env JEMALLOC_CONF="$conf" MALLOC_CONF="$conf" \
        timeout -s INT "${timeout_s}s" "$gdb" -q -batch \
            -ex "set debuginfod enabled off" \
            -ex "set pagination off" \
            -ex "set filename-display absolute" \
            -ex run \
            -ex "thread apply all bt" \
            -ex quit \
            --args "$binary" >"$gdb_log" 2>&1
    rc=$?
    set -e

    if [[ "$rc" == 124 ]]; then
        observed="deadlock"
        return
    fi

    if [[ "$rc" == 0 ]] && grep -q "main: reached" "$gdb_log"; then
        observed="completed"
    else
        observed="failed(${rc})"
    fi
}

detect_case_signals() {
    local raw_dir="$1" profiling="$2"
    local gdb_log="${raw_dir}/gdb-run.txt"

    shim_entered="no"
    shim_returned="no"
    stack_shape="no"

    grep -q "shim: _Unwind_Backtrace entered" "$gdb_log" && shim_entered="yes"
    grep -q "shim: _Unwind_Backtrace returned" "$gdb_log" && shim_returned="yes"

    if [[ "$profiling" == "off" ]]; then
        return
    fi

    if [[ -f "$gdb_log" ]] &&
        grep -q "malloc_init_hard" "$gdb_log" &&
        grep -q "_Unwind_Backtrace" "$gdb_log" &&
        grep -q "dl_iterate_phdr" "$gdb_log" &&
        grep -Eq "dlsym|getOriginalDLIteratePHDR" "$gdb_log" &&
        grep -Eq "calloc|jecalloc|doris_calloc" "$gdb_log"; then
        stack_shape="yes"
    fi
}

decide_verdict() {
    local profiling="$1" expected="$2"

    verdict="fail"
    if [[ "$expected" == "deadlock" ]]; then
        if [[ "$observed" == "deadlock" && "$shim_entered" == "yes" &&
            "$shim_returned" == "no" && "$stack_shape" == "yes" ]]; then
            verdict="pass"
        fi
        return
    fi

    if [[ "$observed" != "completed" ]]; then
        return
    fi
    if [[ "$profiling" == "off" && "$shim_entered" != "no" ]]; then
        return
    fi
    if [[ "$profiling" == "on" && "$shim_returned" != "yes" ]]; then
        return
    fi
    verdict="pass"
}

write_case_summary() {
    local case_id="$1" variant="$2" profiling="$3" expected="$4" raw_dir="$5"
    local summary="${out_dir}/${case_id}.md"

    cat >"$summary" <<EOF
# ${case_id}
- glibc variant: ${variant}
- glibc lib dir: $(glibc_lib_dir "$variant")
- profiling: ${profiling}
- expected: ${expected}
- observed: ${observed}
- exit code: ${rc}
- shim entered: ${shim_entered}
- shim returned: ${shim_returned}
- deadlock stack shape: ${stack_shape}
- verdict: ${verdict}
- raw logs: ${raw_dir}
EOF

    if [[ -f "${raw_dir}/gdb-run.txt" ]]; then
        echo "- stack excerpt:" >>"$summary"
        grep -E "malloc_mutex_lock|malloc_init_hard|prof_boot|prof_unwind_init|_Unwind_Backtrace|dl_iterate_phdr|getOriginalDLIteratePHDR|dlsym|_dlerror_run|calloc|jecalloc|doris_calloc" \
            "${raw_dir}/gdb-run.txt" | sed -n '1,18p' | sed 's/^/  - /' >>"$summary" || true
    fi
}

run_case() {
    local case_id="$1" variant="$2" profiling="$3" expected="$4"
    local binary="${out_root}/bin/${variant}/jemalloc_dl_iterate_phdr_reproducer"
    local raw_dir="${out_dir}/raw/${case_id}"

    [[ -x "$binary" ]] ||
        fail_with_log "missing binary for variant=${variant}; build did not finish"

    mkdir -p "$raw_dir"
    run_process "$binary" "$profiling" "$raw_dir"
    detect_case_signals "$raw_dir" "$profiling"
    decide_verdict "$profiling" "$expected"
    write_case_summary "$case_id" "$variant" "$profiling" "$expected" "$raw_dir"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$case_id" "$variant" "$profiling" "$expected" "$observed" "$stack_shape" "$verdict" \
        >>"$matrix_file"
    [[ "$verdict" == "pass" ]]
}

echo "building glibc/jemalloc matrix"
"${script_dir}/build.sh" >"${out_dir}/build.log" 2>&1 ||
    fail_with_log "failed to build matrix" "${out_dir}/build.log"

printf 'case\tglibc\tprofiling\texpected\tobserved\tstack_shape\tverdict\n' >"$matrix_file"

failures=0
run_case "prev-prof-on" "prev" "on" "deadlock" || failures=$((failures + 1))
run_case "prev-prof-off" "prev" "off" "completed" || failures=$((failures + 1))
run_case "fixed-prof-on" "fixed" "on" "completed" || failures=$((failures + 1))
run_case "fixed-prof-off" "fixed" "off" "completed" || failures=$((failures + 1))

echo "matrix: ${matrix_file}"
column -t -s $'\t' "$matrix_file" || cat "$matrix_file"

if (( failures > 0 )); then
    fail_with_log "${failures} matrix case(s) failed" "$matrix_file"
fi

echo "PASS: glibc dlerror/jemalloc startup matrix matched expectations"
