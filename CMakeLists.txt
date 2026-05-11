cmake_minimum_required(VERSION 3.20)

project(stacktrace_research_repro LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

find_package(Threads REQUIRED)
find_package(PkgConfig QUIET)

function(repo_executable target source output_dir output_name)
  add_executable(${target} ${source})
  target_compile_features(${target} PRIVATE cxx_std_17)
  set_target_properties(${target} PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/${output_dir}"
    OUTPUT_NAME "${output_name}"
  )
endfunction()

function(link_local_unwind target)
  target_link_libraries(${target} PRIVATE unwind unwind-x86_64 Threads::Threads)
endfunction()

repo_executable(
  ck_directed_signal_unwind
  schemes/ck-system-stack-trace/minimal_impl/default/directed_signal_unwind.cpp
  schemes/ck-system-stack-trace/minimal_impl/default/build
  directed_signal_unwind
)
target_compile_options(ck_directed_signal_unwind PRIVATE -O2 -g)
target_link_options(ck_directed_signal_unwind PRIVATE -rdynamic)
link_local_unwind(ck_directed_signal_unwind)

repo_executable(
  ck_fp_vs_unwind_fp
  schemes/ck-system-stack-trace/minimal_impl/fp-build/fp_vs_unwind.cpp
  schemes/ck-system-stack-trace/minimal_impl/fp-build/build
  fp_vs_unwind.fp
)
target_compile_options(
  ck_fp_vs_unwind_fp PRIVATE
  -O2 -g -fno-omit-frame-pointer -fno-optimize-sibling-calls
)
target_link_options(ck_fp_vs_unwind_fp PRIVATE -rdynamic -no-pie)
target_link_libraries(ck_fp_vs_unwind_fp PRIVATE unwind unwind-x86_64 dl)

repo_executable(
  ck_fp_vs_unwind_no_fp
  schemes/ck-system-stack-trace/minimal_impl/fp-build/fp_vs_unwind.cpp
  schemes/ck-system-stack-trace/minimal_impl/fp-build/build
  fp_vs_unwind.no_fp
)
target_compile_options(
  ck_fp_vs_unwind_no_fp PRIVATE
  -O2 -g -fomit-frame-pointer -fno-optimize-sibling-calls
)
target_link_options(ck_fp_vs_unwind_no_fp PRIVATE -rdynamic -no-pie)
target_link_libraries(ck_fp_vs_unwind_no_fp PRIVATE unwind unwind-x86_64 dl)

repo_executable(
  ob_observer_kill60_minimal
  schemes/ob-observer-kill60/minimal_impl/observer_kill60_minimal.cpp
  schemes/ob-observer-kill60/minimal_impl/build
  observer_kill60_minimal
)
target_compile_options(ob_observer_kill60_minimal PRIVATE -O2 -g -fno-omit-frame-pointer)
link_local_unwind(ob_observer_kill60_minimal)

repo_executable(
  ob_open_obstack_target
  schemes/ob-open-obstack-ptrace/minimal_impl/target.cpp
  schemes/ob-open-obstack-ptrace/minimal_impl/build
  target
)
target_compile_options(ob_open_obstack_target PRIVATE -O1 -g -fno-omit-frame-pointer)
target_link_libraries(ob_open_obstack_target PRIVATE Threads::Threads)

repo_executable(
  ob_open_obstack_ptrace_remote_unwind
  schemes/ob-open-obstack-ptrace/minimal_impl/ptrace_remote_unwind.cpp
  schemes/ob-open-obstack-ptrace/minimal_impl/build
  ptrace_remote_unwind
)
target_compile_options(ob_open_obstack_ptrace_remote_unwind PRIVATE -O1 -g -fno-omit-frame-pointer)

if(PkgConfig_FOUND)
  pkg_check_modules(LIBUNWIND_PTRACE QUIET libunwind-ptrace)
endif()

if(LIBUNWIND_PTRACE_FOUND)
  target_include_directories(ob_open_obstack_ptrace_remote_unwind PRIVATE ${LIBUNWIND_PTRACE_INCLUDE_DIRS})
  target_compile_options(ob_open_obstack_ptrace_remote_unwind PRIVATE ${LIBUNWIND_PTRACE_CFLAGS_OTHER})
  target_link_libraries(ob_open_obstack_ptrace_remote_unwind PRIVATE ${LIBUNWIND_PTRACE_LIBRARIES})
  target_link_directories(ob_open_obstack_ptrace_remote_unwind PRIVATE ${LIBUNWIND_PTRACE_LIBRARY_DIRS})
else()
  target_link_libraries(ob_open_obstack_ptrace_remote_unwind PRIVATE unwind-ptrace unwind-x86_64 unwind)
endif()

repo_executable(
  ebpf_profile_target_fp
  shared/ebpf/profile_target/profile_target.cpp
  shared/ebpf/profile_target/build
  profile_target_fp
)
target_compile_options(ebpf_profile_target_fp PRIVATE -O2 -g -fno-omit-frame-pointer)
target_link_libraries(ebpf_profile_target_fp PRIVATE Threads::Threads m)

repo_executable(
  ebpf_profile_target_nofp
  shared/ebpf/profile_target/profile_target.cpp
  shared/ebpf/profile_target/build
  profile_target_nofp
)
target_compile_options(ebpf_profile_target_nofp PRIVATE -O2 -g -fomit-frame-pointer)
target_link_libraries(ebpf_profile_target_nofp PRIVATE Threads::Threads m)

repo_executable(
  risk_ck_unwind_no_phdr_cache
  risk_cases/ck_unwind_without_phdr_cache/ck_unwind_without_phdr_cache.cpp
  risk_cases/ck_unwind_without_phdr_cache/build
  unsafe_no_phdr_cache
)
target_compile_options(risk_ck_unwind_no_phdr_cache PRIVATE -O1 -g -DRISK_USE_PHDR_CACHE=0)
target_link_options(risk_ck_unwind_no_phdr_cache PRIVATE -rdynamic)
target_link_libraries(risk_ck_unwind_no_phdr_cache PRIVATE unwind unwind-x86_64 dl Threads::Threads)

repo_executable(
  risk_ck_unwind_with_phdr_cache
  risk_cases/ck_unwind_without_phdr_cache/ck_unwind_without_phdr_cache.cpp
  risk_cases/ck_unwind_without_phdr_cache/build
  safe_with_phdr_cache
)
target_compile_options(risk_ck_unwind_with_phdr_cache PRIVATE -O1 -g -DRISK_USE_PHDR_CACHE=1)
target_link_options(risk_ck_unwind_with_phdr_cache PRIVATE -rdynamic)
target_link_libraries(risk_ck_unwind_with_phdr_cache PRIVATE unwind unwind-x86_64 dl Threads::Threads)

add_custom_target(
  stacktrace_minimal_impls
  DEPENDS
    ck_directed_signal_unwind
    ck_fp_vs_unwind_fp
    ck_fp_vs_unwind_no_fp
    ob_observer_kill60_minimal
    ob_open_obstack_target
    ob_open_obstack_ptrace_remote_unwind
    ebpf_profile_target_fp
    ebpf_profile_target_nofp
)

add_custom_target(
  stacktrace_risk_cases
  DEPENDS
    risk_ck_unwind_no_phdr_cache
    risk_ck_unwind_with_phdr_cache
)
