#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case_id=${CASE_ID:?CASE_ID is required}
image=${IMAGE:?IMAGE is required}
backend=${JEMALLOC_BACKEND:?JEMALLOC_BACKEND is required}
profiling=${PROFILING:?PROFILING is required}
expected=${EXPECTED:?EXPECTED is required}
timeout_seconds=${TIMEOUT_SECONDS:-8}
jemalloc="$root/.deps/jemalloc-$backend/lib/libjemalloc.so"
wrapper="$root/.build/$backend/out/libphdr_wrap.so"
repro="$root/.build/$backend/out/repro"
summary="$root/results/$case_id.md"
raw_dir="$root/results/raw/$case_id"
if [[ ! -x "$repro" || ! -f "$wrapper" || ! -f "$jemalloc" ]]; then
    echo "missing build artifacts for backend=$backend; run scripts/build.sh first" >&2
    exit 2
fi
rm -rf "$raw_dir"
mkdir -p "$raw_dir"
malloc_conf="prof:false"
[[ "$profiling" == on ]] && malloc_conf="prof:true,prof_active:true,lg_prof_sample:0,prof_prefix:$raw_dir/jeprof"
set +e
env LD_PRELOAD="$wrapper:$jemalloc" MALLOC_CONF="$malloc_conf" \
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
    kill -TERM "$pid" 2>/dev/null; sleep 0.2; kill -KILL "$pid" 2>/dev/null
    wait "$pid" >/dev/null 2>&1
    rc=124
    observed=deadlock
else
    wait "$pid"
    rc=$?
    [[ "$rc" == 0 ]] && observed=completed || observed="failed($rc)"
fi
set -e
stack_shape=no
bt="$raw_dir/gdb-bt.txt"
if [[ -f "$bt" ]] && grep -q "malloc_init_hard" "$bt" \
    && grep -q "_Unwind_Backtrace" "$bt" \
    && grep -q "dl_iterate_phdr" "$bt" \
    && grep -Eq "dlsym|_dlerror_run" "$bt"; then
    stack_shape=yes
fi
verdict=fail
[[ "$expected" == deadlock && "$observed" == deadlock && "$stack_shape" == yes ]] && verdict=pass
[[ "$expected" == completed && "$observed" == completed ]] && verdict=pass
cat >"$summary" <<EOF
# Case $case_id
- image: $image
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
printf '%s|%s|%s|%s\n' "$case_id" "$expected" "$observed" "$verdict"
[[ "$verdict" == pass ]]
