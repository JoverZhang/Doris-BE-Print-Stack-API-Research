#!/usr/bin/env bash

run_case_in_container() {
    local case_id=$1
    local image=$2
    local backend=$3
    local profiling=$4
    local expected=$5
    local timeout_seconds=${TIMEOUT_SECONDS:-8}
    local prefix wrapper repro summary raw_dir malloc_conf pid deadline timed_out rc observed bt stack_shape verdict

    prefix=$(jemalloc_prefix "$backend")
    wrapper="$(backend_build_dir "$backend")/out/libphdr_wrap.so"
    repro="$(backend_build_dir "$backend")/out/repro"
    summary="$results/$case_id.md"
    raw_dir="$results/raw/$case_id"
    [[ -x "$repro" && -f "$wrapper" && -f "$prefix/lib/libjemalloc.so" ]] ||
        die "missing build artifacts for backend=$backend; run just build-jemalloc $backend first"

    rm -rf "$raw_dir"
    mkdir -p "$raw_dir"
    malloc_conf="prof:false"
    [[ "$profiling" == on ]] && malloc_conf="prof:true,prof_active:true,lg_prof_sample:0,prof_prefix:$raw_dir/jeprof"

    set +e
    env LD_PRELOAD="$wrapper:$prefix/lib/libjemalloc.so" MALLOC_CONF="$malloc_conf" \
        "$repro" >"$raw_dir/stdout.log" 2>"$raw_dir/stderr.log" &
    pid=$!
    deadline=$((SECONDS + timeout_seconds))
    timed_out=0
    while kill -0 "$pid" 2>/dev/null; do
        (( SECONDS < deadline )) || { timed_out=1; break; }
        sleep 0.1
    done
    if (( timed_out == 1 )); then
        gdb -batch -p "$pid" -ex "set pagination off" -ex "thread apply all bt" >"$raw_dir/gdb-bt.txt" 2>&1
        kill -TERM "$pid" 2>/dev/null
        sleep 0.2
        kill -KILL "$pid" 2>/dev/null
        wait "$pid" >/dev/null 2>&1
        rc=124
        observed=deadlock
    else
        wait "$pid"
        rc=$?
        [[ "$rc" == 0 ]] && observed=completed || observed="failed($rc)"
    fi
    set -e

    bt="$raw_dir/gdb-bt.txt"
    stack_shape=no
    if [[ -f "$bt" ]] && grep -q "malloc_init_hard" "$bt" \
        && grep -q "_Unwind_Backtrace" "$bt" \
        && grep -q "dl_iterate_phdr" "$bt" \
        && grep -Eq "dlsym|_dlerror_run" "$bt"; then
        stack_shape=yes
    fi

    verdict=fail
    [[ "$expected" == deadlock && "$observed" == deadlock && "$stack_shape" == yes ]] && verdict=pass
    [[ "$expected" == completed && "$observed" == completed ]] && verdict=pass
    write_case_summary "$case_id" "$image" "$backend" "$profiling" "$expected" "$observed" "$rc" "$stack_shape" "$verdict" "$bt"
    printf '%s|%s|%s|%s\n' "$case_id" "$expected" "$observed" "$verdict"
    [[ "$verdict" == pass ]]
}

write_case_summary() {
    local case_id=$1 image=$2 backend=$3 profiling=$4 expected=$5 observed=$6 rc=$7 stack_shape=$8 verdict=$9 bt=${10}
    local summary="$results/$case_id.md"

    cat >"$summary" <<EOF
# Case $case_id
- image: ubuntu:$image
- jemalloc backend: $backend
- profiling: $profiling
- expected: $expected
- observed: $observed
- exit code: $rc
- stack shape: $stack_shape
- verdict: $verdict
- raw logs: results/raw/$case_id/
EOF
    if [[ "$stack_shape" == yes ]]; then
        echo "- stack excerpt:" >>"$summary"
        grep -E "malloc_init_hard|prof_boot|prof_unwind_init|_Unwind_Backtrace|dl_iterate_phdr|dlsym|_dlerror_run|calloc|malloc" "$bt" \
            | sed -n '1,14p' | sed 's/^/  - /' >>"$summary"
    fi
}
