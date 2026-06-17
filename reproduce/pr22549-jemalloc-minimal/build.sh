#!/usr/bin/env bash
# Reason: build the standalone PR 22549/glibc dlerror matrix locally.
# Local: reproduce/pr22549-jemalloc-minimal.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../.." && pwd)"

jemalloc_ref="5.3.0"
jemalloc_src_rel=".mira/research-sources/jemalloc-5.3.0"
jemalloc_src="${project_root}/${jemalloc_src_rel}"
jemalloc_url="https://github.com/jemalloc/jemalloc.git"

glibc_url="https://github.com/bminor/glibc.git"
glibc_prev_name="glibc-dlerror-deadlock-b2964eb"
glibc_prev_commit="b2964eb1d9a6b8ab1250e8a881cf406182da5875"
glibc_fixed_name="glibc-dlerror-base-free-fada901"
glibc_fixed_commit="fada9018199c21c469ff0e731ef75c6020074ac9"

out_root="${script_dir}/.tmp"
jemalloc_work_src="${out_root}/jemalloc-src"
jemalloc_install="${out_root}/jemalloc-install"
glibc_build_root="${out_root}/glibc-build"
glibc_install_root="${out_root}/glibc-install"
binary_root="${out_root}/bin"
log_root="${out_root}/logs"
source_file="${script_dir}/jemalloc_dl_iterate_phdr_reproducer.c"
cc="${CC:-gcc}"
jobs="${JOBS:-$(nproc)}"

die() {
    echo "error: $*" >&2
    exit 1
}

ensure_git_checkout() {
    local rel_path="$1" ref="$2" url="$3"
    local path="${project_root}/${rel_path}"

    if [[ ! -e "$path" ]]; then
        mkdir -p "$(dirname "$path")"
        git clone --filter=blob:none --no-checkout "$url" "$path"
    fi
    git -C "$path" rev-parse --git-dir >/dev/null 2>&1 ||
        die "research source exists but is not a git checkout: ${rel_path}"

    git -C "$path" fetch --filter=blob:none --depth 1 origin "$ref" ||
        git -C "$path" fetch --filter=blob:none --depth 1 origin "tag" "$ref"
    git -C "$path" checkout --detach "$ref"
}

ensure_sources() {
    ensure_git_checkout "$jemalloc_src_rel" "$jemalloc_ref" "$jemalloc_url"
    ensure_git_checkout ".mira/research-sources/${glibc_prev_name}" \
        "$glibc_prev_commit" "$glibc_url"
    ensure_git_checkout ".mira/research-sources/${glibc_fixed_name}" \
        "$glibc_fixed_commit" "$glibc_url"
}

copy_jemalloc_source() {
    rm -rf "$jemalloc_work_src"
    mkdir -p "$jemalloc_work_src"
    tar -C "$jemalloc_src" --exclude .git -cf - . | tar -C "$jemalloc_work_src" -xf -
    printf '%s\n' "$jemalloc_ref" >"${jemalloc_work_src}/VERSION"
}

verify_jemalloc_log() {
    local log_file="${log_root}/jemalloc/configure.log"

    grep -q "prof[[:space:]]*: 1" "$log_file" ||
        die "jemalloc was not configured with profiling"
    grep -q "prof-libgcc[[:space:]]*: 1" "$log_file" ||
        die "jemalloc did not select the libgcc unwind backend"
    grep -q "prof-libunwind[[:space:]]*: 0" "$log_file" ||
        die "jemalloc unexpectedly selected libunwind"
}

build_jemalloc() {
    local archive="${jemalloc_install}/lib/libjemalloc_doris.a"
    local header="${jemalloc_install}/include/jemalloc/jemalloc.h"
    local log_file="${log_root}/jemalloc/configure.log"

    if [[ "${JEMALLOC_REBUILD:-0}" != 1 && -f "$archive" && -f "$header" && -f "$log_file" ]]; then
        verify_jemalloc_log
        return
    fi

    rm -rf "$jemalloc_install"
    copy_jemalloc_source
    mkdir -p "$(dirname "$log_file")"

    (
        cd "$jemalloc_work_src"
        CFLAGS='-O3 -fno-omit-frame-pointer -fPIC -g' ./autogen.sh \
            --prefix="$jemalloc_install" \
            --with-install-suffix="_doris" \
            --with-jemalloc-prefix=je \
            --enable-prof \
            --disable-cxx \
            --disable-libdl \
            --disable-shared >"$log_file" 2>&1
        make -j "$jobs" >>"$log_file" 2>&1
        make install >>"$log_file" 2>&1
    ) || {
        local rc=$?
        echo "error: jemalloc build failed rc=${rc}" >&2
        echo "---- tail ${log_file} ----" >&2
        tail -n 80 "$log_file" >&2 || true
        exit "$rc"
    }

    mv "${jemalloc_install}/include/jemalloc/jemalloc_doris.h" "$header"
    verify_jemalloc_log
}

glibc_source_rel() {
    case "$1" in
        prev) echo ".mira/research-sources/${glibc_prev_name}" ;;
        fixed) echo ".mira/research-sources/${glibc_fixed_name}" ;;
        *) die "unknown glibc variant: $1" ;;
    esac
}

glibc_commit() {
    case "$1" in
        prev) echo "$glibc_prev_commit" ;;
        fixed) echo "$glibc_fixed_commit" ;;
        *) die "unknown glibc variant: $1" ;;
    esac
}

glibc_install_dir() {
    echo "${glibc_install_root}/$1"
}

glibc_build_dir() {
    echo "${glibc_build_root}/$1"
}

glibc_lib_dir() {
    local install_dir
    install_dir="$(glibc_install_dir "$1")"

    if [[ -x "${install_dir}/lib/ld-linux-x86-64.so.2" ]]; then
        echo "${install_dir}/lib"
        return
    fi
    if [[ -x "${install_dir}/lib64/ld-linux-x86-64.so.2" ]]; then
        echo "${install_dir}/lib64"
        return
    fi
    die "cannot find x86_64 glibc loader under ${install_dir}"
}

verify_reproducer_binary() {
    local variant="$1" binary="$2" loader="$3" lib_dir="$4"
    local dynamic_file="${log_root}/binary-${variant}/readelf-dynamic.txt"
    local program_file="${log_root}/binary-${variant}/readelf-program.txt"

    mkdir -p "$(dirname "$dynamic_file")"
    readelf -d "$binary" >"$dynamic_file"
    readelf -l "$binary" >"$program_file"

    grep -Fq "[Requesting program interpreter: ${loader}]" "$program_file" ||
        die "binary ${variant} does not use the target glibc loader"
    grep -Eq "Library r(un)?path: \\[${lib_dir}\\]" "$dynamic_file" ||
        die "binary ${variant} does not pin the target glibc library path"
    ! grep -Eq "Shared library: \\[(libstdc\\+\\+|libgcc_s)\\.so" "$dynamic_file" ||
        die "binary ${variant} unexpectedly depends on host C++/libgcc runtime"
}

build_glibc() {
    local variant="$1"
    local src_rel src build_dir install_dir log_file marker

    [[ "$(uname -m)" == "x86_64" ]] ||
        die "this reproducer currently supports x86_64 glibc only"

    src_rel="$(glibc_source_rel "$variant")"
    src="${project_root}/${src_rel}"
    build_dir="$(glibc_build_dir "$variant")"
    install_dir="$(glibc_install_dir "$variant")"
    log_file="${log_root}/glibc-${variant}/build.log"
    marker="${install_dir}/.build-complete-$(glibc_commit "$variant")"

    if [[ "${GLIBC_REBUILD:-0}" != 1 && -x "${install_dir}/lib/ld-linux-x86-64.so.2" &&
        -f "${install_dir}/lib/libc.so.6" && -f "$marker" ]]; then
        return
    fi

    rm -rf "$build_dir" "$install_dir"
    mkdir -p "$build_dir" "$install_dir" "$(dirname "$log_file")"

    (
        cd "$build_dir"
        CFLAGS="${GLIBC_CFLAGS:--O2 -g -U_FORTIFY_SOURCE}" \
            "${src}/configure" \
            --prefix="$install_dir" \
            --disable-werror \
            --disable-mathvec \
            --disable-timezone-tools \
            --disable-build-nscd \
            --disable-nscd \
            --with-gd=no \
            --enable-kernel=3.2.0
        make -j "$jobs"
        make install
    ) >"$log_file" 2>&1 || {
        local rc=$?
        echo "error: glibc ${variant} build failed rc=${rc}" >&2
        echo "---- tail ${log_file} ----" >&2
        tail -n 120 "$log_file" >&2 || true
        exit "$rc"
    }

    glibc_lib_dir "$variant" >/dev/null
    touch "$marker"
}

build_reproducer_for_glibc() {
    local variant="$1"
    local install_dir lib_dir loader obj_dir obj binary crtbegin crtend

    install_dir="$(glibc_install_dir "$variant")"
    lib_dir="$(glibc_lib_dir "$variant")"
    loader="${lib_dir}/ld-linux-x86-64.so.2"
    obj_dir="${out_root}/obj/${variant}"
    obj="${obj_dir}/jemalloc_dl_iterate_phdr_reproducer.o"
    binary="${binary_root}/${variant}/jemalloc_dl_iterate_phdr_reproducer"
    crtbegin="$("$cc" -print-file-name=crtbegin.o)"
    crtend="$("$cc" -print-file-name=crtend.o)"

    mkdir -p "$obj_dir" "$(dirname "$binary")"

    "$cc" -O0 -g -Wall -Wextra -std=c11 -fno-stack-protector -fno-pie \
        -I"${jemalloc_install}/include" \
        -isystem "${install_dir}/include" \
        -c "$source_file" \
        -o "$obj"

    "$cc" -no-pie -nostdlib -nostartfiles -rdynamic \
        -Wl,--dynamic-linker="$loader" \
        -Wl,-rpath="$lib_dir" \
        "${lib_dir}/crt1.o" \
        "${lib_dir}/crti.o" \
        "$crtbegin" \
        "$obj" \
        "${jemalloc_install}/lib/libjemalloc_doris.a" \
        -Wl,--start-group \
        -L"$lib_dir" \
        -lc -ldl -lpthread -lm \
        -Wl,--end-group \
        -lgcc \
        "$crtend" \
        "${lib_dir}/crtn.o" \
        -o "$binary"

    verify_reproducer_binary "$variant" "$binary" "$loader" "$lib_dir"
    echo "$binary"
}

main() {
    ensure_sources
    build_jemalloc
    for variant in prev fixed; do
        echo "building glibc ${variant} ($(glibc_commit "$variant"))"
        build_glibc "$variant"
        echo "building reproducer for glibc ${variant}"
        build_reproducer_for_glibc "$variant"
    done
}

main "$@"
