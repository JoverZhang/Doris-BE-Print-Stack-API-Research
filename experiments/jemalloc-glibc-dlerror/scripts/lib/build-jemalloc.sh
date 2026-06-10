#!/usr/bin/env bash

build_llvm_libunwind() {
    local build=$1 jobs=$2
    local src="$cache/src/llvm-project-$llvm_version.src/runtimes"
    local obj="$build/libunwind-build"
    local install="$deps/llvm-libunwind"
    local cmake

    fetch_tarball \
        "https://github.com/llvm/llvm-project/releases/download/llvmorg-$llvm_version/llvm-project-$llvm_version.src.tar.xz" \
        "llvm-project-$llvm_version.src.tar.xz" \
        "llvm-project-$llvm_version.src"
    [[ -f "$install/lib/libunwind.a" || -f "$install/lib64/libunwind.a" ]] && return
    cmake=$(cmake_bin)
    rm -rf "$obj"
    "$cmake" -S "$src" -B "$obj" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$install" -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DLLVM_ENABLE_RUNTIMES=libunwind -DLLVM_INCLUDE_TESTS=OFF \
        -DLIBUNWIND_ENABLE_SHARED=ON -DLIBUNWIND_ENABLE_STATIC=ON \
        -DLIBUNWIND_ENABLE_TESTS=OFF -DLIBUNWIND_INSTALL_HEADERS=ON
    "$cmake" --build "$obj" --target install --parallel "$jobs"
}

build_unw_backtrace_archive() {
    local build=$1 unwind_prefix=$2 unwind_lib_dir=$3 compat="$build/libunwind-compat"

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

build_jemalloc_backend() {
    local backend=$1
    local jobs=${JOBS:-$(nproc 2>/dev/null || echo 2)}
    local build prefix out src obj log
    local args=(--enable-prof --enable-shared --disable-static --disable-prof-gcc)
    local cppflags=${CPPFLAGS:-}
    local ldflags=${LDFLAGS:-}

    require_backend "$backend"
    build=$(backend_build_dir "$backend")
    prefix=$(jemalloc_prefix "$backend")
    out="$build/out"
    src="$cache/src/jemalloc-$jemalloc_version"
    obj="$build/jemalloc-build"
    log="$build/jemalloc-configure.log"
    mkdir -p "$cache/src" "$cache/downloads" "$build" "$deps" "$out"
    fetch_tarball \
        "https://github.com/jemalloc/jemalloc/releases/download/$jemalloc_version/jemalloc-$jemalloc_version.tar.bz2" \
        "jemalloc-$jemalloc_version.tar.bz2" \
        "jemalloc-$jemalloc_version"

    args=(--prefix="$prefix" "${args[@]}")
    if [[ "$backend" == llvm-libunwind ]]; then
        local unwind_prefix="$deps/llvm-libunwind"
        local unwind_lib_dir="$unwind_prefix/lib"
        build_llvm_libunwind "$build" "$jobs"
        [[ -d "$unwind_lib_dir" ]] || unwind_lib_dir="$unwind_prefix/lib64"
        build_unw_backtrace_archive "$build" "$unwind_prefix" "$unwind_lib_dir"
        args+=(--enable-prof-libunwind --disable-prof-libgcc)
        args+=(--with-static-libunwind="$unwind_lib_dir/libunwind_jemalloc.a")
        cppflags="$cppflags -I$build/libunwind-compat/include -I$unwind_prefix/include"
        ldflags="$ldflags -L$unwind_lib_dir -Wl,-rpath,$unwind_lib_dir"
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
    check_jemalloc_config "$backend" "$log"
    build_repro_bits "$backend"
}

check_jemalloc_config() {
    local backend=$1 log=$2 want_unwind want_libgcc

    grep -q "prof[[:space:]]*: 1" "$log"
    case "$backend" in
        llvm-libunwind) want_unwind=1; want_libgcc=0 ;;
        *) want_unwind=0; want_libgcc=1 ;;
    esac
    grep -q "prof-libunwind[[:space:]]*: $want_unwind" "$log"
    grep -q "prof-libgcc[[:space:]]*: $want_libgcc" "$log"
}

build_repro_bits() {
    local backend=$1
    local out
    out="$(backend_build_dir "$backend")/out"

    cc -O0 -g -fPIC -shared "$root/src/phdr_wrap.c" -o "$out/libphdr_wrap.so" -ldl
    cc -O0 -g "$root/src/repro.c" -o "$out/repro"
}
