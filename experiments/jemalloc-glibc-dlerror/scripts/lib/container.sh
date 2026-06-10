#!/usr/bin/env bash

container_lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$container_lib_dir/../.." && pwd)

container_engine() {
    if [[ -n "${ENGINE:-}" ]]; then
        echo "$ENGINE"
    elif command -v podman >/dev/null 2>&1; then
        echo podman
    else
        echo docker
    fi
}

container_run_args() {
    printf '%s\n' run --rm -v "$root:/work" -w /work --cap-add SYS_PTRACE --security-opt seccomp=unconfined
}

build_image() {
    local version=$1 engine tag
    engine=$(container_engine)
    tag="jemalloc-glibc-dlerror:ubuntu-$version"

    "$engine" build -f "$root/Containerfile" --build-arg "UBUNTU_VERSION=$version" -t "$tag" "$root" >/dev/null
    echo "$tag"
}

run_in_image() {
    local image=$1 engine
    shift
    engine=$(container_engine)
    "$engine" $(container_run_args) "$image" "$@"
}
