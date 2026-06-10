#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
engine=${ENGINE:-}
if [[ -z "$engine" ]]; then
    command -v podman >/dev/null 2>&1 && engine=podman || engine=docker
fi
run_args=(run --rm -v "$root:/work" -w /work)
run_args+=(--cap-add SYS_PTRACE --security-opt seccomp=unconfined)
build_image() {
    local version=$1
    local tag="jemalloc-glibc-dlerror:ubuntu-${version}"
    "$engine" build -f "$root/Containerfile" --build-arg "UBUNTU_VERSION=$version" -t "$tag" "$root" >/dev/null
    printf '%s\n' "$tag"
}
run_case() {
    local case_id=$1 ubuntu=$2 backend=$3 profiling=$4 expected=$5 image=$6
    "$engine" "${run_args[@]}" "$image" env JEMALLOC_BACKEND="$backend" bash ./scripts/build.sh >/dev/null
    "$engine" "${run_args[@]}" "$image" env CASE_ID="$case_id" IMAGE="ubuntu:$ubuntu" \
        JEMALLOC_BACKEND="$backend" PROFILING="$profiling" EXPECTED="$expected" bash ./scripts/run-one.sh
}
mkdir -p "$root/results"
image20=$(build_image "20.04")
image24=$(build_image "24.04")
run_case A 20.04 libgcc on deadlock "$image20"
run_case B 20.04 libgcc off completed "$image20"
run_case C 20.04 llvm-libunwind on completed "$image20"
run_case D 24.04 libgcc on completed "$image24"
printf '\n| Case | Expected | Observed | Verdict |\n'
printf '|---|---|---|---|\n'
for case_id in A B C D; do
    expected=$(sed -n 's/^- expected: //p' "$root/results/$case_id.md")
    observed=$(sed -n 's/^- observed: //p' "$root/results/$case_id.md")
    verdict=$(sed -n 's/^- verdict: //p' "$root/results/$case_id.md")
    printf '| %s | %s | %s | %s |\n' "$case_id" "$expected" "$observed" "$verdict"
done
