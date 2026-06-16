#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "$0")"

cxx=${CXX:-c++}

if [[ -n "${CXXFLAGS:-}" ]]
then
    read -r -a cxxflags <<< "$CXXFLAGS"
else
    cxxflags=(-O0 -g -Wall -Wextra -std=c++17 -pthread)
fi

if [[ -n "${LDLIBS:-}" ]]
then
    read -r -a ldlibs <<< "$LDLIBS"
else
    ldlibs=(-ldl -pthread)
fi

"$cxx" "${cxxflags[@]}" \
    dl_iterate_phdr_signal_reentry.cpp \
    -o dl_iterate_phdr_signal_reentry \
    "${ldlibs[@]}"
