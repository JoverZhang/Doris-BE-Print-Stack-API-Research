cmake_minimum_required(VERSION 3.20)
project(jemalloc_glibc_dlerror C)

include(ExternalProject)
include(ProcessorCount)

set(JEMALLOC_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/deps/jemalloc")
set(LLVM_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/deps/llvm-project")
set(LOCAL_DEPS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/.deps")
set(LOCAL_BUILD_DIR "${CMAKE_CURRENT_SOURCE_DIR}/.build")

ProcessorCount(host_jobs)
if(NOT host_jobs)
    set(host_jobs 2)
endif()

if(NOT EXISTS "${JEMALLOC_SOURCE_DIR}/autogen.sh")
    message(FATAL_ERROR "Missing jemalloc submodule. Run: git submodule update --init --depth 1 -- experiments/jemalloc-glibc-dlerror/deps/jemalloc")
endif()
if(NOT EXISTS "${LLVM_SOURCE_DIR}/runtimes/CMakeLists.txt")
    message(FATAL_ERROR "Missing LLVM submodule. Run: git submodule update --init --depth 1 -- experiments/jemalloc-glibc-dlerror/deps/llvm-project")
endif()

function(add_repro_targets backend)
    string(REPLACE "-" "_" target_suffix "${backend}")
    set(out_dir "${LOCAL_BUILD_DIR}/${backend}/out")

    add_library(phdr_wrap_${target_suffix} SHARED src/phdr_wrap.c)
    set_target_properties(phdr_wrap_${target_suffix} PROPERTIES
        OUTPUT_NAME phdr_wrap
        LIBRARY_OUTPUT_DIRECTORY "${out_dir}")
    target_link_libraries(phdr_wrap_${target_suffix} PRIVATE dl)

    add_executable(repro_${target_suffix} src/repro.c)
    set_target_properties(repro_${target_suffix} PROPERTIES
        OUTPUT_NAME repro
        RUNTIME_OUTPUT_DIRECTORY "${out_dir}")

    add_custom_target(repro-bits-${backend}
        DEPENDS phdr_wrap_${target_suffix} repro_${target_suffix})
endfunction()

ExternalProject_Add(llvm-libunwind
    SOURCE_DIR "${LLVM_SOURCE_DIR}/runtimes"
    BINARY_DIR "${LOCAL_BUILD_DIR}/llvm-libunwind-build"
    INSTALL_DIR "${LOCAL_DEPS_DIR}/llvm-libunwind"
    CMAKE_ARGS
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_INSTALL_PREFIX=<INSTALL_DIR>
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
        -DLLVM_ENABLE_RUNTIMES=libunwind
        -DLLVM_INCLUDE_TESTS=OFF
        -DLLVM_LIBDIR_SUFFIX=
        -DLIBUNWIND_ENABLE_SHARED=ON
        -DLIBUNWIND_ENABLE_STATIC=ON
        -DLIBUNWIND_ENABLE_TESTS=OFF
        -DLIBUNWIND_INSTALL_HEADERS=ON
    BUILD_BYPRODUCTS "${LOCAL_DEPS_DIR}/llvm-libunwind/lib/libunwind.a")

set(unwind_install "${LOCAL_DEPS_DIR}/llvm-libunwind")
set(unwind_lib_dir "${unwind_install}/lib")
set(unwind_compat_dir "${LOCAL_BUILD_DIR}/llvm-libunwind-compat")
set(unwind_compat_archive "${unwind_lib_dir}/libunwind_jemalloc.a")

add_custom_command(
    OUTPUT "${unwind_compat_archive}"
    COMMAND "${CMAKE_COMMAND}" -E rm -rf "${unwind_compat_dir}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${unwind_compat_dir}"
    COMMAND "${CMAKE_C_COMPILER}" -O2 -fPIC -I"${unwind_install}/include"
            -c "${CMAKE_CURRENT_SOURCE_DIR}/cmake/libunwind-compat/unw_backtrace.c"
            -o "${unwind_compat_dir}/unw_backtrace.o"
    COMMAND "${CMAKE_COMMAND}" -E copy "${unwind_lib_dir}/libunwind.a" "${unwind_compat_archive}"
    COMMAND "${CMAKE_AR}" rcs "${unwind_compat_archive}" "${unwind_compat_dir}/unw_backtrace.o"
    DEPENDS llvm-libunwind "${CMAKE_CURRENT_SOURCE_DIR}/cmake/libunwind-compat/unw_backtrace.c")

add_custom_target(libunwind-jemalloc-archive DEPENDS "${unwind_compat_archive}")

function(add_jemalloc_backend backend)
    set(prefix "${LOCAL_DEPS_DIR}/jemalloc-${backend}")
    set(source_copy "${CMAKE_BINARY_DIR}/src/jemalloc-${backend}")
    set(log_file "${LOCAL_BUILD_DIR}/${backend}/jemalloc-configure.log")
    set(common_args "--enable-prof --enable-shared --disable-static --disable-prof-gcc")
    set(cppflags "")
    set(ldflags "")
    set(extra_dep "")

    if("${backend}" STREQUAL "llvm-libunwind")
        set(unwind_args "--enable-prof-libunwind --disable-prof-libgcc --with-static-libunwind=${unwind_compat_archive}")
        set(cppflags "-I${CMAKE_CURRENT_SOURCE_DIR}/cmake/libunwind-compat -I${unwind_install}/include")
        set(ldflags "-L${unwind_lib_dir} -Wl,-rpath,${unwind_lib_dir}")
        set(extra_dep "libunwind-jemalloc-archive")
    else()
        set(unwind_args "--disable-prof-libunwind")
    endif()

    ExternalProject_Add(jemalloc-${backend}
        SOURCE_DIR "${source_copy}"
        DOWNLOAD_COMMAND
            "${CMAKE_COMMAND}" -E rm -rf "<SOURCE_DIR>"
            COMMAND "${CMAKE_COMMAND}" -E copy_directory "${JEMALLOC_SOURCE_DIR}" "<SOURCE_DIR>"
        CONFIGURE_COMMAND
            /bin/sh -c "cd '<SOURCE_DIR>' && CPPFLAGS='${cppflags}' LDFLAGS='${ldflags}' ./autogen.sh --prefix='${prefix}' ${common_args} ${unwind_args} | tee '${log_file}'"
        BUILD_COMMAND make -C "<SOURCE_DIR>" -j${host_jobs} build_lib_shared
        INSTALL_COMMAND make -C "<SOURCE_DIR>" install_lib install_include
        BUILD_BYPRODUCTS "${prefix}/lib/libjemalloc.so"
        DEPENDS ${extra_dep})

    add_custom_target(verify-jemalloc-${backend}
        COMMAND grep -q "prof[[:space:]]*: 1" "${log_file}"
        COMMAND grep -q "prof-libunwind[[:space:]]*: $<IF:$<STREQUAL:${backend},llvm-libunwind>,1,0>" "${log_file}"
        COMMAND grep -q "prof-libgcc[[:space:]]*: $<IF:$<STREQUAL:${backend},llvm-libunwind>,0,1>" "${log_file}"
        DEPENDS jemalloc-${backend})

    add_repro_targets("${backend}")
    add_custom_target(backend-${backend}
        DEPENDS verify-jemalloc-${backend} repro-bits-${backend})
endfunction()

add_jemalloc_backend(libgcc)
add_jemalloc_backend(llvm-libunwind)
