#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR"

./build.sh

DSO="$BASE_DIR/build/libdoris_bench_dso.so"
OUT="$BASE_DIR/bench.csv"
SMOKE_OUT="$BASE_DIR/doris_poc_smoke.out"
RUT_OUT="$BASE_DIR/doris_poc_remote_unwind_test.out"
rm -f "$OUT" "$SMOKE_OUT" "$RUT_OUT"

# Sanity: dump-then-symbolize both impls.
./build/doris_poc_smoke spin 4 > "$SMOKE_OUT" 2>&1
echo "smoke complete: $SMOKE_OUT"
head -20 "$SMOKE_OUT"
echo "..."

# Correctness: remote_unwind must match unw_init_local2 on the same ucontext.
./build/doris_poc_remote_unwind_test > "$RUT_OUT" 2>&1
echo "remote_unwind_test complete: $RUT_OUT"
grep '^match=' "$RUT_OUT"

read -ra THREAD_COUNTS <<< "${DORIS_POC_THREADS:-4 32 128}"
ITERS="${DORIS_POC_ITERS:-100}"
WARMUP="${DORIS_POC_WARMUP:-10}"
TIMEOUT_MS="${DORIS_POC_TIMEOUT_MS:-100}"

first=1
run_one() {
  local impl="$1" wl="$2" n="$3" cv="$4"
  local args=(
    --impl="$impl"
    --workload="$wl"
    --threads="$n"
    --iters="$ITERS"
    --warmup="$WARMUP"
    --timeout-ms="$TIMEOUT_MS"
    --out="$OUT"
    --dso="$DSO"
  )
  if [[ "$first" == "1" ]]; then args+=(--write-header); first=0; fi
  echo "running impl=$impl workload=$wl threads=$n copy=$cv ..."
  ./build/doris_poc_bench_${cv} "${args[@]}"
}

# Phase 1 — impl comparison at the primary 8 KiB copy size. This is the
# headline matrix referenced by README.md.
for impl in kill60 snapshot; do
  for wl in idle spin alloc lock dlopen; do
    for n in "${THREAD_COUNTS[@]}"; do
      run_one "$impl" "$wl" "$n" 8k
    done
  done
done

# Phase 2 — copy-size ablation for snapshot, spin workload only. Used to
# justify the 8 KiB default.
if [[ "${DORIS_POC_SKIP_ABLATION:-0}" != "1" ]]; then
  for cv in 4k 16k 32k; do
    for n in "${THREAD_COUNTS[@]}"; do
      run_one snapshot spin "$n" "$cv"
    done
  done
fi

# Phase 3 (optional) — full cross product of impls / workloads / copy sizes.
# Off by default because most cells are uninteresting (kill60 ignores copy
# size). Set DORIS_POC_FULL_MATRIX=1 to enable.
if [[ "${DORIS_POC_FULL_MATRIX:-0}" == "1" ]]; then
  for cv in 4k 16k 32k; do
    for wl in idle alloc lock dlopen; do
      for n in "${THREAD_COUNTS[@]}"; do
        run_one snapshot "$wl" "$n" "$cv"
      done
    done
  done
fi

echo "wrote: $OUT"
wc -l "$OUT"
echo "configs:"
awk -F, 'NR>1 {print $1, $2, $3, $4}' "$OUT" | sort -u | wc -l
echo "head:"
head -2 "$OUT"
echo "tail:"
tail -3 "$OUT"
