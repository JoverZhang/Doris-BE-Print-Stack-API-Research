#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR"

./build.sh

DSO="$BASE_DIR/build/libdoris_bench_dso.so"
OUT="$BASE_DIR/bench.csv"
SMOKE_OUT="$BASE_DIR/doris_poc_smoke.out"
rm -f "$OUT" "$SMOKE_OUT"

# Quick sanity dump first.
./build/doris_poc_smoke spin 4 > "$SMOKE_OUT" 2>&1
echo "smoke complete: $SMOKE_OUT"
head -20 "$SMOKE_OUT"
echo "..."

# Sweep matrix. Skip the redundant kill60 runs across copy_bytes — kill60 does
# not use the copy buffer, only snapshot does.
IMPLS=(kill60 snapshot)
WORKLOADS=(idle spin alloc lock dlopen)
read -ra THREAD_COUNTS <<< "${DORIS_POC_THREADS:-4 32 128}"
read -ra COPY_VARIANTS <<< "${DORIS_POC_COPY_VARIANTS:-4k 8k 16k 32k}"
ITERS="${DORIS_POC_ITERS:-200}"
WARMUP="${DORIS_POC_WARMUP:-20}"
TIMEOUT_MS="${DORIS_POC_TIMEOUT_MS:-100}"

first=1
for cv in "${COPY_VARIANTS[@]}"; do
  for impl in "${IMPLS[@]}"; do
    [[ "$impl" == "kill60" && "$cv" != "8k" ]] && continue
    for wl in "${WORKLOADS[@]}"; do
      for n in ${THREAD_COUNTS[@]}; do
        args=(
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
      done
    done
  done
done

echo "wrote: $OUT"
wc -l "$OUT"
echo "head:"
head -2 "$OUT"
echo "tail:"
tail -3 "$OUT"
