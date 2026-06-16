#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "$0")"

cxx=${CXX:-c++}
default_libunwind_root="$PWD/../../.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind"
libunwind_root=${OCEANBASE_LIBUNWIND_ROOT:-$default_libunwind_root}
libunwind_lib_dir=${OCEANBASE_LIBUNWIND_LIB_DIR:-$libunwind_root/_build-local/src/.libs}

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
    ldlibs=(
        "-L$libunwind_lib_dir"
        "-Wl,-rpath,$libunwind_lib_dir"
        -lunwind
        -pthread
    )
fi

"$cxx" "${cxxflags[@]}" \
    libunwind_signal_deadlock_reproducer.cpp \
    -o libunwind_signal_deadlock_reproducer \
    "${ldlibs[@]}"
