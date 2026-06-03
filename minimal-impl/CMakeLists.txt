cmake_minimum_required(VERSION 3.16)
project(minimal_impl CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

set(BUILD_VARIANT "release_fp" CACHE STRING
    "Build variant: asan | tsan | release_fp | release_nofp")

if(BUILD_VARIANT STREQUAL "asan")
    add_compile_options(-O1 -g -fno-omit-frame-pointer -fsanitize=address)
    add_link_options(-fsanitize=address)
elseif(BUILD_VARIANT STREQUAL "tsan")
    add_compile_options(-O1 -g -fno-omit-frame-pointer -fsanitize=thread)
    add_link_options(-fsanitize=thread)
elseif(BUILD_VARIANT STREQUAL "release_fp")
    add_compile_options(-O3 -DNDEBUG -g -fno-omit-frame-pointer)
elseif(BUILD_VARIANT STREQUAL "release_nofp")
    add_compile_options(-O3 -DNDEBUG -g -fomit-frame-pointer)
else()
    message(FATAL_ERROR "Unknown BUILD_VARIANT=${BUILD_VARIANT} "
                        "(expected: asan|tsan|release_fp|release_nofp)")
endif()

find_path(LIBUNWIND_INCLUDE_DIR libunwind.h REQUIRED)
find_library(LIBUNWIND_LIB NAMES unwind REQUIRED)

find_path(LIBDW_INCLUDE_DIR elfutils/libdw.h REQUIRED)
find_library(LIBDW_LIB NAMES dw REQUIRED)
find_library(LIBELF_LIB NAMES elf REQUIRED)

message(STATUS "BUILD_VARIANT  = ${BUILD_VARIANT}")
message(STATUS "libunwind      = ${LIBUNWIND_LIB}")
message(STATUS "libdw          = ${LIBDW_LIB}")
message(STATUS "libelf         = ${LIBELF_LIB}")

add_executable(min_stack_collect
    src/main.cpp
    src/stack_walker_fp.cpp
    src/stack_walker_unwind.cpp
    src/signal_harness.cpp
    src/workload.cpp
)
target_include_directories(min_stack_collect PRIVATE src ${LIBUNWIND_INCLUDE_DIR})
target_link_libraries(min_stack_collect PRIVATE ${LIBUNWIND_LIB} dl)
# -rdynamic exports the workload symbols into .dynsym so dladdr() can name
# them in the verifier. Without it dladdr only sees imported dynsyms.
target_link_options(min_stack_collect PRIVATE -rdynamic)

# elf_inspect is a host analysis tool; building it under a sanitizer would
# instrument libdw/libelf paths and is wasteful, so only build under release.
if(BUILD_VARIANT MATCHES "^release")
    add_executable(elf_inspect tools/elf_inspect.cpp)
    target_include_directories(elf_inspect PRIVATE ${LIBDW_INCLUDE_DIR})
    target_link_libraries(elf_inspect PRIVATE ${LIBDW_LIB} ${LIBELF_LIB})
endif()
