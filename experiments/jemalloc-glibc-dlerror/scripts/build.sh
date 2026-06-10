#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
backend=${JEMALLOC_BACKEND:-libgcc}
jobs=${JOBS:-$(nproc 2>/dev/null || echo 2)}
jemalloc_version=5.3.0
llvm_version=17.0.6
cmake_version=3.27.9
cache="$root/.cache"
build="$root/.build/$backend"
deps="$root/.deps"
prefix="$deps/jemalloc-$backend"
out="$build/out"
cmake_bin=cmake

case "$backend" in libgcc|llvm-libunwind) ;; *)
    echo "JEMALLOC_BACKEND must be libgcc or llvm-libunwind" >&2
    exit 2
esac

mkdir -p "$cache/src" "$cache/downloads" "$build" "$deps" "$out"

fetch_tarball() {
    local url=$1 archive=$2 dirname=$3
    [[ -f "$cache/src/$dirname/.extracted" ]] && return
    [[ -f "$cache/downloads/$archive" ]] || curl -fL "$url" -o "$cache/downloads/$archive"
    rm -rf "$cache/src/$dirname"
    tar --no-same-owner -xf "$cache/downloads/$archive" -C "$cache/src"
    touch "$cache/src/$dirname/.extracted"
}

ensure_new_cmake() {
    local dir="cmake-$cmake_version-linux-x86_64"
    fetch_tarball "https://github.com/Kitware/CMake/releases/download/v$cmake_version/$dir.tar.gz" "$dir.tar.gz" "$dir"
    cmake_bin="$cache/src/$dir/bin/cmake"
}

build_llvm_libunwind() {
    local src="$cache/src/llvm-project-$llvm_version.src/runtimes"
    local obj="$build/libunwind-build"
    local install="$deps/llvm-libunwind"
    fetch_tarball "https://github.com/llvm/llvm-project/releases/download/llvmorg-$llvm_version/llvm-project-$llvm_version.src.tar.xz" \
        "llvm-project-$llvm_version.src.tar.xz" "llvm-project-$llvm_version.src"
    [[ -f "$install/lib/libunwind.a" || -f "$install/lib64/libunwind.a" ]] && return
    ensure_new_cmake
    rm -rf "$obj"
    "$cmake_bin" -S "$src" -B "$obj" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$install" -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DLLVM_ENABLE_RUNTIMES=libunwind -DLLVM_INCLUDE_TESTS=OFF \
        -DLIBUNWIND_ENABLE_SHARED=ON -DLIBUNWIND_ENABLE_STATIC=ON \
        -DLIBUNWIND_ENABLE_TESTS=OFF -DLIBUNWIND_INSTALL_HEADERS=ON
    "$cmake_bin" --build "$obj" --target install --parallel "$jobs"
}

build_unw_backtrace_archive() {
    local unwind_prefix=$1 unwind_lib_dir=$2 compat="$build/libunwind-compat"
    rm -rf "$compat"
    mkdir -p "$compat/include"
    cat >"$compat/include/libunwind.h" <<'SRC'
#ifndef JEMALLOC_LLVM_UNW_BACKTRACE_H
#define JEMALLOC_LLVM_UNW_BACKTRACE_H
#include_next <libunwind.h>
int unw_backtrace(void **buffer, int size);
#endif
SRC
    cat >"$compat/unw_backtrace.c" <<'SRC'
#define UNW_LOCAL_ONLY
#include <libunwind.h>

int unw_backtrace(void **buffer, int size) {
    unw_context_t context;
    unw_cursor_t cursor;
    unw_word_t ip;
    int n = 0;

    if (size <= 0 || unw_getcontext(&context) < 0 ||
            unw_init_local(&cursor, &context) < 0) {
        return 0;
    }
    while (n < size && unw_step(&cursor) > 0) {
        if (unw_get_reg(&cursor, UNW_REG_IP, &ip) < 0) {
            break;
        }
        buffer[n++] = (void *)ip;
    }
    return n;
}
SRC
    cc -O2 -fPIC -I"$unwind_prefix/include" -c "$compat/unw_backtrace.c" -o "$compat/unw_backtrace.o"
    cp "$unwind_lib_dir/libunwind.a" "$unwind_lib_dir/libunwind_jemalloc.a"
    ar rcs "$unwind_lib_dir/libunwind_jemalloc.a" "$compat/unw_backtrace.o"
}

build_jemalloc() {
    local src="$cache/src/jemalloc-$jemalloc_version"
    local obj="$build/jemalloc-build"
    local log="$build/jemalloc-configure.log"
    local args=(--prefix="$prefix" --enable-prof --enable-shared --disable-static --disable-prof-gcc)
    local cppflags=${CPPFLAGS:-}
    local ldflags=${LDFLAGS:-}
    fetch_tarball "https://github.com/jemalloc/jemalloc/releases/download/$jemalloc_version/jemalloc-$jemalloc_version.tar.bz2" \
        "jemalloc-$jemalloc_version.tar.bz2" "jemalloc-$jemalloc_version"
    if [[ "$backend" == llvm-libunwind ]]; then
        build_llvm_libunwind
        local unwind_prefix="$deps/llvm-libunwind"
        local unwind_lib_dir="$unwind_prefix/lib"
        [[ -d "$unwind_lib_dir" ]] || unwind_lib_dir="$unwind_prefix/lib64"
        args+=(--enable-prof-libunwind --disable-prof-libgcc)
        build_unw_backtrace_archive "$unwind_prefix" "$unwind_lib_dir"
        cppflags="$cppflags -I$build/libunwind-compat/include -I$unwind_prefix/include"
        ldflags="$ldflags -L$unwind_lib_dir -Wl,-rpath,$unwind_lib_dir"
        args+=(--with-static-libunwind="$unwind_lib_dir/libunwind_jemalloc.a")
    else
        args+=(--disable-prof-libunwind)
    fi
    rm -rf "$obj" "$prefix"
    mkdir -p "$obj"
    (
        cd "$obj"
        CPPFLAGS="$cppflags" LDFLAGS="$ldflags" "$src/configure" "${args[@]}" | tee "$log"
        make -j"$jobs" build_lib_shared
        make install_lib install_include
    )
    grep -q "prof[[:space:]]*: 1" "$log"
    case "$backend" in llvm-libunwind) want_unwind=1; want_libgcc=0 ;; *) want_unwind=0; want_libgcc=1 ;; esac
    grep -q "prof-libunwind[[:space:]]*: $want_unwind" "$log"
    grep -q "prof-libgcc[[:space:]]*: $want_libgcc" "$log"
}

build_repro_bits() {
    cc -O0 -g -fPIC -shared "$root/src/phdr_wrap.c" -o "$out/libphdr_wrap.so" -ldl
    cc -O0 -g "$root/src/repro.c" -o "$out/repro"
}

build_jemalloc
build_repro_bits
echo "built backend=$backend"
echo "jemalloc=$prefix/lib/libjemalloc.so"
echo "wrapper=$out/libphdr_wrap.so"
echo "repro=$out/repro"
