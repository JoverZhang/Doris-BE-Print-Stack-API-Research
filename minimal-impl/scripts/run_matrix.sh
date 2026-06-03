#!/usr/bin/env bash
# Run every variant × walker, print a markdown matrix.
set -uo pipefail

cd "$(dirname "$0")/.."

VARIANTS=(asan tsan release_fp release_nofp)
WALKERS=(fp unwind)
ITERS=50

run_cell() {
    local variant="$1" walker="$2"
    local bin="build/$variant/min_stack_collect"
    if [[ ! -x "$bin" ]]; then
        echo "no-build"
        return
    fi
    # capture full result line; never let a failure abort the matrix
    local out
    out=$("$bin" --walker "$walker" --mode signal --iters "$ITERS" --verify 2>&1) || true
    if grep -q "result=PASS" <<<"$out"; then
        # extract empty/passed/wrong counts to put in the cell
        local empty passed wrong depth
        empty=$(grep -oE "empty=[0-9]+" <<<"$out" | head -1 | cut -d= -f2)
        depth=$(grep -oE "depth_avg=[0-9.]+" <<<"$out" | head -1 | cut -d= -f2)
        echo "PASS d=${depth}"
    else
        local empty passed wrong
        empty=$(grep -oE "empty=[0-9]+" <<<"$out" | head -1 | cut -d= -f2)
        passed=$(grep -oE "passed=[0-9]+" <<<"$out" | head -1 | cut -d= -f2)
        wrong=$(grep -oE "wrong=[0-9]+" <<<"$out" | head -1 | cut -d= -f2)
        echo "FAIL e=${empty:-?} p=${passed:-?} w=${wrong:-?}"
    fi
}

printf "Matrix: %d iterations per cell, mode=signal, --verify\n\n" "$ITERS"

# Header
printf "| Walker \\ Variant |"
for v in "${VARIANTS[@]}"; do printf " %s |" "$v"; done
printf "\n"
printf "%s" "|---|"
for v in "${VARIANTS[@]}"; do printf "%s" "---|"; done
printf "\n"

# Body
for w in "${WALKERS[@]}"; do
    printf "| %s |" "$w"
    for v in "${VARIANTS[@]}"; do
        cell=$(run_cell "$v" "$w")
        printf " %s |" "$cell"
    done
    printf "\n"
done

echo
echo "Legend:"
echo "  PASS d=N   : all iterations verified, average trace depth N"
echo "  FAIL e=E p=P w=W : E empty traces, P passed verify, W wrong (mis-resolved)"
echo "  no-build   : variant not built yet"
