#!/usr/bin/env bash

fetch_tarball() {
    local url=$1 archive=$2 dirname=$3

    mkdir -p "$cache/src" "$cache/downloads"
    [[ -f "$cache/src/$dirname/.extracted" ]] && return
    [[ -f "$cache/downloads/$archive" ]] || curl -fL "$url" -o "$cache/downloads/$archive"
    rm -rf "$cache/src/$dirname"
    tar --no-same-owner -xf "$cache/downloads/$archive" -C "$cache/src"
    touch "$cache/src/$dirname/.extracted"
}

cmake_bin() {
    local dir="cmake-$cmake_version-linux-x86_64"

    fetch_tarball \
        "https://github.com/Kitware/CMake/releases/download/v$cmake_version/$dir.tar.gz" \
        "$dir.tar.gz" \
        "$dir"
    echo "$cache/src/$dir/bin/cmake"
}
