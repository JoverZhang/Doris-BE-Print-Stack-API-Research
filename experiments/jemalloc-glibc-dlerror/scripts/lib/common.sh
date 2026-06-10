#!/usr/bin/env bash

common_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$common_dir/../.." && pwd)

jemalloc_version=5.3.0
llvm_version=17.0.6
cmake_version=3.27.9

cache="$root/.cache"
deps="$root/.deps"
results="$root/results"

die() {
    echo "$*" >&2
    exit 2
}

require_backend() {
    case "${1:-}" in
        libgcc|llvm-libunwind) ;;
        *) die "backend must be libgcc or llvm-libunwind" ;;
    esac
}

case_row() {
    case "${1:-}" in
        A) echo "20.04 libgcc on deadlock" ;;
        B) echo "20.04 libgcc off completed" ;;
        C) echo "20.04 llvm-libunwind on completed" ;;
        D) echo "24.04 libgcc on completed" ;;
        *) die "case must be A, B, C, or D" ;;
    esac
}

image_tag() {
    echo "jemalloc-glibc-dlerror:ubuntu-$1"
}

backend_build_dir() {
    echo "$root/.build/$1"
}

jemalloc_prefix() {
    echo "$deps/jemalloc-$1"
}
