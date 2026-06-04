---
title: ClickHouse system.stack_trace Implementation Research
created_at: 2026-06-04T13:16:30+08:00
workspace_root: /home/mira/lab/projects/Doris-BE-Print-Stack-API-Research
target_source_root: /home/mira/lab/projects/Doris-BE-Print-Stack-API-Research/repos/source/ClickHouse-v26.3.10.62-lts
target_branch: detached HEAD, tag v26.3.10.62-lts
target_commit: e1c11930c28196f954a93287e43c1aa112c8c607
depth: deep
request: "Use $mira-code-research to analyze the system stacktrace implementation in repos/source/ClickHouse-v26.3.10.62-lts; follow-up: include ClickHouse's patched LLVM/libunwind, jemalloc, and contrib/jemalloc-cmake/CMakeLists.txt."
---

# ClickHouse system.stack_trace Implementation Research

## Question

How does ClickHouse's `system.stack_trace` system table collect stack traces from every thread in the server process, what startup and build prerequisites does it rely on, and what signal-safety and concurrency boundaries does it impose? Also trace the shared unwind substrate, especially ClickHouse's vendored LLVM/libunwind addition of `unw_backtrace()`, how `jemalloc-cmake` selects that symbol, and how jemalloc allocation profiling sends sampled stacks to `system.trace_log`.

## Scope

In scope:

- `src/Storages/System/StorageSystemStackTrace.{h,cpp}`: system table schema, signal handler, and read source.
- `src/Storages/System/attachSystemTables.cpp`, `programs/server/Server.cpp`, `programs/local/LocalServer.cpp`, and `programs/main.cpp`: system table attachment and PHDR cache startup prerequisites.
- `src/Common/StackTrace.{h,cpp}`, `base/base/phdr_cache.{h,cpp}`, `contrib/libunwind-cmake/`, and `contrib/llvm-project/libunwind/`: low-level unwind path, PHDR cache, and ClickHouse-local `unw_backtrace()` patch surface.
- `contrib/jemalloc/`, `contrib/jemalloc-cmake/`, `src/Common/Jemalloc.{h,cpp}`, `src/Common/TraceSender.{h,cpp}`, and jemalloc query settings in `ThreadStatusExt`: the adjacent allocation profiling path that shares the unwinder.
- `docs/en/operations/system-tables/stack_trace.md`, `docs/en/operations/allocation-profiling.md`, and related stateless/integration tests: user-facing contracts and proof.

Out of scope:

- The full consumer, flush, and thread-lifecycle implementation of `system.trace_log`; this report follows only the `JemallocSample` producer and validation points.
- Text stack traces in exception logs, query logs, and crash logs, except as adjacent implementations.
- Doris Phase 1 material and Doris patch implementation.

Source acquisition:

- none. The existing local source tree was used; no fetch, submodule update, or clone was run.
- Snapshot was confirmed by reading files: `.git/HEAD:1` is a detached commit; `.git/packed-refs:2197` and `.git/packed-refs:2198` show that tag `v26.3.10.62-lts` peels to this commit.
- Local `.gitmodules` shows `contrib/jemalloc` points to upstream `jemalloc/jemalloc`, while `contrib/llvm-project` points to `ClickHouse/llvm-project`: `.gitmodules:34`, `.gitmodules:36`, `.gitmodules:218`, `.gitmodules:220`.

## Executive Summary

- `system.stack_trace` is an OS-gated system storage: it is compiled only on Linux and Darwin, attached as `system.stack_trace`, and exposed with table engine name `SystemStackTrace`. It is not a `SYSTEM ...` statement.
- The main read path is: query planning creates `ReadFromSystemStackTrace`, the source enumerates threads, then projection and predicate analysis decide whether to read thread names and whether to signal target threads. The signal path is used only when `trace`, `query_id`, or `untracked_memory` is requested.
- On Linux, collection uses `SIGRTMIN` plus `rt_tgsigqueueinfo(tgid, tid, ...)` to target each thread. The handler runs in the target thread, captures `StackTrace(ucontext_t)`, reads `CurrentThread::query_id` and `untracked_memory`, then notifies the reader through a pipe.
- On Linux, `StackTrace` calls `unw_backtrace()` by default. This is not merely a system libunwind API assumption: ClickHouse's vendored LLVM/libunwind header marks the symbol as a "ClickHouse addition", and the implementation comment says it was "added for jemalloc". This is the key local-patch surface.
- ClickHouse's `contrib/jemalloc-cmake/CMakeLists.txt` explicitly builds jemalloc profiling with `JEMALLOC_PROF_LIBUNWIND=1` and links `_jemalloc` against `unwind`. The stated reason is to avoid a potential `_Unwind_Backtrace()` deadlock during jemalloc bootstrap when `dlsym` allocates. jemalloc's `prof_sys.c` calls `unw_backtrace()` under that define.
- `system.stack_trace` and jemalloc samples are different producers. The former is a live all-thread system table. The latter is a jemalloc profiler hook installed by `Jemalloc::setup()` that sends `TraceType::JemallocSample` into the trace pipe and is surfaced through `system.trace_log`. They share ClickHouse's libunwind, PHDR, and symbolization substrate and should be reviewed together when porting or comparing implementations.

## Evidence Map

| Claim | Classification | Evidence | Confidence |
|---|---|---|---|
| `system.stack_trace` is compiled only on Linux and Darwin. | guard | `src/Storages/System/StorageSystemStackTrace.cpp:1`, `src/Storages/System/StorageSystemStackTrace.h:3` | high |
| Server system table attachment adds `StorageSystemStackTrace` as `stack_trace` only on Linux and Darwin. | prerequisite | `src/Storages/System/attachSystemTables.cpp:212`, `src/Storages/System/attachSystemTables.cpp:213` | high |
| Server startup attaches system tables after the system database is created. | prerequisite | `programs/server/Server.cpp:2844`, `programs/server/Server.cpp:2845` | high |
| clickhouse-local also attaches server system tables on its default path. | prerequisite | `programs/local/LocalServer.cpp:1127`, `programs/local/LocalServer.cpp:1135` | high |
| The table schema includes `thread_name`, `thread_id`, `query_id`, `trace`, and `untracked_memory`. | direct | `src/Storages/System/StorageSystemStackTrace.cpp:729`, `src/Storages/System/StorageSystemStackTrace.cpp:734` | high |
| `trace` is an address array, and the docs describe it as physical addresses. | config-doc | `docs/en/operations/system-tables/stack_trace.md:22`, `docs/en/operations/system-tables/stack_trace.md:25` | high |
| The constructor opens the notification pipe and installs the service signal handler. | direct | `src/Storages/System/StorageSystemStackTrace.cpp:738`, `src/Storages/System/StorageSystemStackTrace.cpp:757` | high |
| The Linux service signal is `SIGRTMIN`; Darwin uses `SIGUSR1`. | guard | `src/Storages/System/StorageSystemStackTrace.cpp:77`, `src/Storages/System/StorageSystemStackTrace.cpp:80` | high |
| The handler forbids allocations, validates sender and sequence, captures `StackTrace(signal_context)`, and writes to the pipe. | safety-contract | `src/Storages/System/StorageSystemStackTrace.cpp:120`, `src/Storages/System/StorageSystemStackTrace.cpp:182` | high |
| The handler reads the target thread's current query id, copies at most 128 bytes, and reads untracked memory. | direct | `src/Storages/System/StorageSystemStackTrace.cpp:105`, `src/Storages/System/StorageSystemStackTrace.cpp:170` | high |
| The read source uses a global mutex to prevent concurrent reads of this table. | safety-contract | `src/Storages/System/StorageSystemStackTrace.cpp:93`, `src/Storages/System/StorageSystemStackTrace.cpp:101`, `src/Storages/System/StorageSystemStackTrace.cpp:407`, `src/Storages/System/StorageSystemStackTrace.cpp:409` | high |
| The source signals threads only when `trace`, `query_id`, or `untracked_memory` is requested; id/name-only reads can avoid signals. | direct | `src/Storages/System/StorageSystemStackTrace.cpp:411`, `src/Storages/System/StorageSystemStackTrace.cpp:414`, `src/Storages/System/StorageSystemStackTrace.cpp:466` | high |
| Linux thread ids are enumerated from `/proc/self/task` and then predicate-filtered. | direct | `src/Storages/System/StorageSystemStackTrace.cpp:660`, `src/Storages/System/StorageSystemStackTrace.cpp:679` | high |
| Thread names are read from `/proc/self/task/<tid>/comm` and can be predicate-filtered before signaling. | direct | `src/Storages/System/StorageSystemStackTrace.cpp:234`, `src/Storages/System/StorageSystemStackTrace.cpp:283` | high |
| Before sending a signal on Linux, the reader checks whether the target thread blocks the service signal to avoid waiting uselessly. | safety-contract | `src/Storages/System/StorageSystemStackTrace.cpp:294`, `src/Storages/System/StorageSystemStackTrace.cpp:327`, `src/Storages/System/StorageSystemStackTrace.cpp:476`, `src/Storages/System/StorageSystemStackTrace.cpp:484` | high |
| Linux uses `rt_tgsigqueueinfo` to send a sequence-bearing realtime signal to a specific tid, then waits on the pipe with a timeout. | direct | `src/Storages/System/StorageSystemStackTrace.cpp:502`, `src/Storages/System/StorageSystemStackTrace.cpp:519` | high |
| The Darwin path uses `pthread_kill` and an expected pthread id to avoid delayed-handler cross-talk. | guard | `src/Storages/System/StorageSystemStackTrace.cpp:520`, `src/Storages/System/StorageSystemStackTrace.cpp:548` | high |
| After a successful Linux capture, runtime virtual addresses are converted to object-relative physical addresses before insertion into `trace`. | direct | `src/Storages/System/StorageSystemStackTrace.cpp:551`, `src/Storages/System/StorageSystemStackTrace.cpp:570` | high |
| `StackTrace` uses `unw_backtrace` on Linux and `backtrace` on Darwin. | dependency | `src/Common/StackTrace.cpp:507`, `src/Common/StackTrace.cpp:514` | high |
| The vendored LLVM/libunwind declaration of `unw_backtrace` is marked as a ClickHouse addition. | local-patch-surface | `contrib/llvm-project/libunwind/include/libunwind.h:118`, `contrib/llvm-project/libunwind/include/libunwind.h:119` | high |
| The `unw_backtrace` implementation comment says it was added by ClickHouse for jemalloc, and the implementation fills a frame buffer with `unw_getcontext`, `unw_init_local`, `unw_step`, and `unw_get_reg(UNW_REG_IP)`. | local-patch-surface | `contrib/llvm-project/libunwind/src/libunwind.cpp:221`, `contrib/llvm-project/libunwind/src/libunwind.cpp:222`, `contrib/llvm-project/libunwind/src/libunwind.cpp:231`, `contrib/llvm-project/libunwind/src/libunwind.cpp:236` | high |
| ClickHouse's libunwind CMake adapter takes sources from `contrib/llvm-project/libunwind` and adds `unwind-override.c`. | build-contract | `contrib/libunwind-cmake/CMakeLists.txt:1`, `contrib/libunwind-cmake/CMakeLists.txt:4`, `contrib/libunwind-cmake/CMakeLists.txt:12`, `contrib/libunwind-cmake/CMakeLists.txt:13` | high |
| `unwind-override.c` overrides C `backtrace()` with `unw_backtrace()` outside Darwin. | build-contract | `contrib/libunwind-cmake/unwind-override.c:5`, `contrib/libunwind-cmake/unwind-override.c:6`, `contrib/libunwind-cmake/unwind-override.c:8` | high |
| `StackTrace(ucontext_t)` adjusts its offset with the signal-context caller address or uses that address as a fallback. | direct | `src/Common/StackTrace.cpp:470`, `src/Common/StackTrace.cpp:499` | high |
| `StackTrace` comments state that signal-safe calculation requires calling `updatePHDRCache()` beforehand. | safety-contract | `src/Common/StackTrace.h:25`, `src/Common/StackTrace.h:27` | high |
| The universal `main()` calls `updatePHDRCache()` before dispatching to the selected application. | prerequisite | `programs/main.cpp:314`, `programs/main.cpp:318` | high |
| PHDR cache is enabled only on Linux excluding TSan and musl; otherwise `hasPHDRCache()` can be false. | guard | `base/base/phdr_cache.cpp:7`, `base/base/phdr_cache.cpp:13`, `base/base/phdr_cache.cpp:117`, `base/base/phdr_cache.cpp:124` | high |
| Linux builds explicitly enable async unwind tables, and libunwind is included through CMake. | build-contract | `CMakeLists.txt:232`, `CMakeLists.txt:240`, `cmake/unwind.cmake:1`, `cmake/unwind.cmake:2` | high |
| Preserving frame pointers is not the default; it is added by the `DISABLE_OMIT_FRAME_POINTER` option and sanitizer flags. | build-contract | `CMakeLists.txt:309`, `CMakeLists.txt:316`, `cmake/sanitize.cmake:9` | high |
| `contrib/jemalloc` is an upstream jemalloc submodule, while `contrib/llvm-project` is a ClickHouse llvm-project submodule. | dependency | `.gitmodules:34`, `.gitmodules:36`, `.gitmodules:218`, `.gitmodules:220` | high |
| `jemalloc-cmake` enables jemalloc after sanitizer/platform gates and uses `contrib/jemalloc` as its source directory. | build-contract | `contrib/jemalloc-cmake/CMakeLists.txt:1`, `contrib/jemalloc-cmake/CMakeLists.txt:11`, `contrib/jemalloc-cmake/CMakeLists.txt:69` | high |
| The `jemalloc-cmake` include adapter is placed before jemalloc's own include directory to override generated headers. | build-contract | `contrib/jemalloc-cmake/CMakeLists.txt:142`, `contrib/jemalloc-cmake/CMakeLists.txt:144`, `contrib/jemalloc-cmake/CMakeLists.txt:147`, `contrib/jemalloc-cmake/CMakeLists.txt:148` | high |
| ClickHouse compiles jemalloc profiler support, selects `JEMALLOC_PROF_LIBUNWIND=1`, and links `unwind`. | build-contract | `contrib/jemalloc-cmake/CMakeLists.txt:197`, `contrib/jemalloc-cmake/CMakeLists.txt:199`, `contrib/jemalloc-cmake/CMakeLists.txt:211`, `contrib/jemalloc-cmake/CMakeLists.txt:212` | high |
| `jemalloc-cmake` comments explain that selecting the libunwind flavor avoids a possible `_Unwind_Backtrace()` deadlock during jemalloc bootstrap when `dlsym` allocates. | build-contract | `contrib/jemalloc-cmake/CMakeLists.txt:203`, `contrib/jemalloc-cmake/CMakeLists.txt:205`, `contrib/jemalloc-cmake/CMakeLists.txt:209`, `contrib/jemalloc-cmake/CMakeLists.txt:210` | high |
| jemalloc's own source includes libunwind and uses `unw_backtrace()` for profiler backtraces under `JEMALLOC_PROF_LIBUNWIND`. | dependency | `contrib/jemalloc/src/prof_sys.c:10`, `contrib/jemalloc/src/prof_sys.c:12`, `contrib/jemalloc/src/prof_sys.c:53`, `contrib/jemalloc/src/prof_sys.c:63` | high |
| jemalloc's default profiler backtrace hook points to `prof_backtrace_impl`; the LIBGCC-only bootstrap init does not call `_Unwind_Backtrace()` in the LIBUNWIND path. | dependency | `contrib/jemalloc/src/prof_sys.c:531`, `contrib/jemalloc/src/prof_sys.c:533`, `contrib/jemalloc/src/prof_sys.c:539`, `contrib/jemalloc/src/prof_sys.c:541` | high |
| ClickHouse server daemon setup calls `Jemalloc::setup()` during startup and again after fork in the child. | prerequisite | `src/Daemon/BaseDaemon.cpp:254`, `src/Daemon/BaseDaemon.cpp:255`, `src/Daemon/BaseDaemon.cpp:596`, `src/Daemon/BaseDaemon.cpp:601` | high |
| `Jemalloc::setup()` installs experimental sample/free/dump hooks, with the global collection flag driven by config. | adjacent | `src/Common/Jemalloc.cpp:169`, `src/Common/Jemalloc.cpp:190`, `src/Common/Jemalloc.cpp:191`, `src/Common/Jemalloc.cpp:193` | high |
| The jemalloc allocation hook forbids allocations, copies jemalloc's backtrace, and sends `TraceType::JemallocSample`. | adjacent | `src/Common/Jemalloc.cpp:102`, `src/Common/Jemalloc.cpp:104`, `src/Common/Jemalloc.cpp:110`, `src/Common/Jemalloc.cpp:114` | high |
| `TraceSender::send()` has recursion protection, forbids allocations, constrains writes to a single atomic pipe write, and serializes stack frames plus trace type. | safety-contract | `src/Common/TraceSender.cpp:33`, `src/Common/TraceSender.cpp:41`, `src/Common/TraceSender.cpp:45`, `src/Common/TraceSender.cpp:63`, `src/Common/TraceSender.cpp:99` | high |
| `TraceType` includes `JemallocSample`, and `TraceSender::send()` states that a `TraceCollector` object must already exist. | adjacent | `src/Common/TraceSender.h:15`, `src/Common/TraceSender.h:23`, `src/Common/TraceSender.h:47`, `src/Common/TraceSender.h:49` | high |
| Query-level jemalloc settings activate the profiler and set a thread-local trace-log collection flag, then reset that flag on detach. | config-doc | `src/Interpreters/ThreadStatusExt.cpp:379`, `src/Interpreters/ThreadStatusExt.cpp:386`, `src/Interpreters/ThreadStatusExt.cpp:447`, `src/Interpreters/ThreadStatusExt.cpp:450` | high |
| Server and query settings document that jemalloc samples can be stored in `system.trace_log`. | config-doc | `src/Core/ServerSettings.cpp:1249`, `src/Core/ServerSettings.cpp:1251`, `src/Core/Settings.cpp:7423`, `src/Core/Settings.cpp:7428` | high |
| Allocation profiling docs state that ClickHouse uses jemalloc and can store `JemallocSample` records in `system.trace_log`. | config-doc | `docs/en/operations/allocation-profiling.md:14`, `docs/en/operations/allocation-profiling.md:20`, `docs/en/operations/allocation-profiling.md:48`, `docs/en/operations/allocation-profiling.md:52` | high |
| User-side symbolization requires introspection functions, whose entry points call `checkAccess`. | guard | `docs/en/operations/system-tables/stack_trace.md:33`, `docs/en/operations/system-tables/stack_trace.md:42`, `src/Functions/addressToSymbol.cpp:35`, `src/Functions/addressToSymbol.cpp:39` | high |
| Existing tests acknowledge that `system.stack_trace` collection is racy and require only that repeated attempts eventually find a DB symbol. | test-proof | `tests/queries/0_stateless/03565_system_stack_trace_works.sh:7`, `tests/queries/0_stateless/03565_system_stack_trace_works.sh:12` | high |
| Optimization tests prove that projection and predicates affect whether signals are sent. | test-proof | `tests/queries/0_stateless/02940_system_stacktrace_optimizations.sh:10`, `tests/queries/0_stateless/02940_system_stacktrace_optimizations.sh:20` | high |
| The jemalloc per-query stateless test requires a `JemallocSample` in `system.trace_log` after enabling query settings. | test-proof | `tests/queries/0_stateless/03594_jemalloc_per_query_sampling.sh:2`, `tests/queries/0_stateless/03594_jemalloc_per_query_sampling.sh:11`, `tests/queries/0_stateless/03594_jemalloc_per_query_sampling.sh:15` | high |
| The jemalloc global profiler integration test validates global and per-query trace-log sample collection. | test-proof | `tests/integration/test_jemalloc_global_profiler/test.py:40`, `tests/integration/test_jemalloc_global_profiler/test.py:66`, `tests/integration/test_jemalloc_global_profiler/test.py:101`, `tests/integration/test_jemalloc_global_profiler/test.py:125` | high |

## Discovery Matrix

| Axis | Seeds / Commands | Findings | Result |
|---|---|---|---|
| Runtime call path | `rg -n "StorageSystemStackTrace|system\\.stack_trace"` | `src/Storages/System/attachSystemTables.cpp:212`, `src/Storages/System/StorageSystemStackTrace.cpp:761`, `src/Storages/System/StorageSystemStackTrace.cpp:774`, `src/Storages/System/StorageSystemStackTrace.cpp:688`, `src/Storages/System/StorageSystemStackTrace.cpp:424` | direct |
| Startup prerequisites | `rg -n "attachSystemTablesServer|updatePHDRCache|Jemalloc::setup"` | `programs/server/Server.cpp:2845`, `programs/local/LocalServer.cpp:1128`, `programs/main.cpp:314`, `programs/main.cpp:318`, `src/Daemon/BaseDaemon.cpp:255`, `src/Daemon/BaseDaemon.cpp:601` | prerequisite |
| Build/link/compiler contract | `rg -n "libunwind|asynchronous-unwind|DISABLE_OMIT_FRAME_POINTER|JEMALLOC_PROF_LIBUNWIND|JEMALLOC_PROF_LIBGCC"` | `cmake/unwind.cmake:2`, `cmake/linux/default_libs.cmake:72`, `CMakeLists.txt:232`, `CMakeLists.txt:240`, `CMakeLists.txt:309`, `CMakeLists.txt:316`, `contrib/jemalloc-cmake/CMakeLists.txt:197`, `contrib/jemalloc-cmake/CMakeLists.txt:211`, `contrib/jemalloc-cmake/CMakeLists.txt:212` | build-contract |
| Platform/feature gates | `rg -n "OS_LINUX|OS_DARWIN|SIGRTMIN|hasPHDRCache|ENABLE_JEMALLOC|SANITIZE"` | `src/Storages/System/StorageSystemStackTrace.cpp:1`, `src/Storages/System/StorageSystemStackTrace.cpp:77`, `src/Storages/System/StorageSystemStackTrace.cpp:80`, `base/base/phdr_cache.cpp:7`, `base/base/phdr_cache.cpp:124`, `contrib/jemalloc-cmake/CMakeLists.txt:1`, `contrib/jemalloc-cmake/CMakeLists.txt:9` | guard |
| Signal, concurrency, and allocation safety | `rg -n "DENY_ALLOCATIONS|mutex|wait\\(|rt_tgsigqueueinfo|pthread_kill|isSignalBlocked|pre_reentrancy|PIPE_BUF"` | `src/Storages/System/StorageSystemStackTrace.cpp:93`, `src/Storages/System/StorageSystemStackTrace.cpp:123`, `src/Storages/System/StorageSystemStackTrace.cpp:175`, `src/Storages/System/StorageSystemStackTrace.cpp:381`, `src/Storages/System/StorageSystemStackTrace.cpp:519`, `src/Common/Jemalloc.cpp:104`, `src/Common/TraceSender.cpp:41`, `src/Common/TraceSender.cpp:63` | safety-contract |
| Dependency, vendored fork, and local patch surface | `rg -n "unw_backtrace|ClickHouse addition|added for jemalloc|unwind-override|SymbolIndex|addressToLine|addressToSymbol" contrib/llvm-project/libunwind contrib/libunwind-cmake src/Common src/Functions` | `src/Common/StackTrace.cpp:507`, `contrib/llvm-project/libunwind/include/libunwind.h:118`, `contrib/llvm-project/libunwind/src/libunwind.cpp:221`, `contrib/libunwind-cmake/CMakeLists.txt:12`, `contrib/libunwind-cmake/unwind-override.c:8`, `src/Common/SymbolIndex.cpp:723`, `src/Functions/addressToLine.h:89` | local-patch-surface |
| Jemalloc adjacent producer | `rg -n "JemallocSample|jemalloc_collect_profile_samples|experimental\\.hooks|prof_sample|prof_backtrace_impl|unw_backtrace" src contrib/jemalloc contrib/jemalloc-cmake docs tests` | `contrib/jemalloc/src/prof_sys.c:63`, `src/Common/Jemalloc.cpp:191`, `src/Common/Jemalloc.cpp:114`, `src/Common/TraceSender.h:23`, `src/Interpreters/ThreadStatusExt.cpp:386`, `docs/en/operations/allocation-profiling.md:52`, `tests/queries/0_stateless/03594_jemalloc_per_query_sampling.sh:15` | adjacent |
| Tests, configs, docs | `rg -n "system\\.stack_trace|storage_system_stack_trace_pipe_read_timeout_ms|JemallocSample|allocation-profiling"` | `docs/en/operations/system-tables/stack_trace.md:16`, `docs/en/operations/system-tables/stack_trace.md:42`, `tests/queries/0_stateless/02117_show_create_table_system.reference:1087`, `tests/queries/0_stateless/02940_system_stacktrace_optimizations.sh:12`, `tests/queries/0_stateless/03594_jemalloc_per_query_sampling.sh:15`, `tests/integration/test_jemalloc_global_profiler/test.py:44` | proof/config/docs |
| Negative search space | `rg -n "STACK_TRACE|STACKTRACE|StackTrace|stack_trace|stacktrace" src/Parsers src/Interpreters/InterpreterSystemQuery.cpp src/Interpreters/InterpreterSystemQuery.h` | no parser/interpreter `SYSTEM STACKTRACE` path found; only unrelated parser test prints `StackTrace().toString()` in destructor test at `src/Parsers/tests/gtest_ast_deleter.cpp:49` | searched-no-hit |
| Negative search space | `rg -n "hasPHDRCache" src/Storages/System/StorageSystemStackTrace.cpp` | no storage-level guard found; PHDR guard/logging exists for QueryProfiler/TraceCollector at `programs/server/Server.cpp:1346` | searched-no-hit |
| Negative search space | `git -C contrib/jemalloc status --short`, `git -C contrib/jemalloc remote -v`, `git -C contrib/jemalloc blame -L 53,68 -- src/prof_sys.c` | no local dirty patch found in `contrib/jemalloc`; local evidence shows upstream remote and grafted/shallow blame. Treat the jemalloc source path as a dependency contract activated by the ClickHouse adapter, not as a proven ClickHouse fork delta. | searched-no-hit |

## Implementation Path

`system.stack_trace` live table path:

1. `programs/main.cpp:314` - the universal executable initializes PHDR cache before choosing the concrete ClickHouse application.
2. `programs/server/Server.cpp:2845` - server startup attaches system tables after system database creation.
3. `src/Storages/System/attachSystemTables.cpp:212` - `StorageSystemStackTrace` is attached only on Linux/Darwin.
4. `src/Storages/System/StorageSystemStackTrace.cpp:724` - the constructor defines schema, opens the pipe, and installs the service signal handler.
5. `src/Storages/System/StorageSystemStackTrace.cpp:761` - table `read()` creates a `ReadFromSystemStackTrace` query-plan step.
6. `src/Storages/System/StorageSystemStackTrace.cpp:688` - the plan step initializes the pipeline with `StackTraceSource`.
7. `src/Storages/System/StorageSystemStackTrace.cpp:411` - the source inspects requested columns to decide whether signal collection is needed.
8. `src/Storages/System/StorageSystemStackTrace.cpp:656` - the source enumerates and filters thread ids.
9. `src/Storages/System/StorageSystemStackTrace.cpp:234` - the optional thread-name pass reads `/proc/self/task/<tid>/comm` and filters before signaling.
10. `src/Storages/System/StorageSystemStackTrace.cpp:502` - the Linux signal path queues `SIGRTMIN` to each target tid one by one.
11. `src/Storages/System/StorageSystemStackTrace.cpp:120` - the target-thread handler captures stack/query/memory data and notifies by pipe.
12. `src/Storages/System/StorageSystemStackTrace.cpp:551` - the reading side copies captured frames, converts them to stored addresses, and inserts output rows.

Shared unwinder and jemalloc path:

1. `cmake/unwind.cmake:2` - the build includes ClickHouse `contrib/libunwind-cmake`.
2. `contrib/libunwind-cmake/CMakeLists.txt:1` - the adapter builds from `contrib/llvm-project/libunwind`.
3. `contrib/llvm-project/libunwind/include/libunwind.h:118` - `unw_backtrace()` is declared as a ClickHouse addition.
4. `contrib/llvm-project/libunwind/src/libunwind.cpp:221` - the implementation says this helper was added for jemalloc.
5. `src/Common/StackTrace.cpp:507` - Linux `StackTrace` uses the same `unw_backtrace()` symbol.
6. `contrib/jemalloc-cmake/CMakeLists.txt:211` - ClickHouse builds jemalloc with `JEMALLOC_PROF_LIBUNWIND=1`.
7. `contrib/jemalloc/src/prof_sys.c:63` - the jemalloc profiler backtrace implementation calls `unw_backtrace(vec, max_len)`.
8. `src/Daemon/BaseDaemon.cpp:255` - ClickHouse initializes jemalloc hooks during daemon setup.
9. `src/Common/Jemalloc.cpp:191` - ClickHouse installs `experimental.hooks.prof_sample` to receive jemalloc allocation samples.
10. `src/Common/Jemalloc.cpp:114` - the allocation hook sends stack samples as `TraceType::JemallocSample`.
11. `src/Common/TraceSender.cpp:99` - trace sender serializes the trace type after stack frames into the trace pipe.

## Preconditions And Contracts

Startup prerequisites:

- `programs/main.cpp:314` - PHDR cache is established before stack unwinding is needed.
- `programs/server/Server.cpp:2845` - the server must attach virtual system tables for `system.stack_trace` to exist.
- `programs/local/LocalServer.cpp:1133` - clickhouse-local can skip system tables only when `no-system-tables` is set; otherwise it attaches them.
- `src/Daemon/BaseDaemon.cpp:255` - jemalloc profiling hooks are installed during daemon setup when `USE_JEMALLOC` is enabled.
- `src/Daemon/BaseDaemon.cpp:601` - a forked child reapplies jemalloc settings because jemalloc background threads and other state do not survive fork.

Build/link/compiler prerequisites:

- `cmake/unwind.cmake:2` - the bundled libunwind CMake subtree is part of the build.
- `contrib/libunwind-cmake/CMakeLists.txt:12` - the ClickHouse adapter adds `unwind-override.c`, with a comment tying it to `unw_backtrace`.
- `contrib/llvm-project/libunwind/include/libunwind.h:118` - `unw_backtrace` is a local ClickHouse addition in vendored LLVM/libunwind.
- `contrib/jemalloc-cmake/CMakeLists.txt:197` - jemalloc profiler support is compiled in.
- `contrib/jemalloc-cmake/CMakeLists.txt:211` - ClickHouse selects jemalloc's libunwind profiler flavor.
- `contrib/jemalloc-cmake/CMakeLists.txt:212` - `_jemalloc` links privately against `unwind`, so `prof_sys.c` can resolve `unw_backtrace`.
- `CMakeLists.txt:237` - non-Darwin builds explicitly add async unwind tables for the Query Profiler; this is adjacent but relevant because `StackTrace` shares unwinding machinery.
- `CMakeLists.txt:310` - keeping frame pointers is optional via `DISABLE_OMIT_FRAME_POINTER`; the `system.stack_trace` path does not rely on frame-pointer walking as its primary implementation.
- `cmake/sanitize.cmake:9` - sanitizer builds force `-fno-omit-frame-pointer`, but `base/base/phdr_cache.cpp:7` disables PHDR cache under TSan.

Runtime guards:

- `src/Storages/System/StorageSystemStackTrace.cpp:1` - the entire implementation is compiled only for Linux/Darwin.
- `src/Storages/System/StorageSystemStackTrace.cpp:77` - Linux uses a realtime signal.
- `src/Storages/System/StorageSystemStackTrace.cpp:126` - the Linux handler rejects signals not sent by the server pid.
- `src/Storages/System/StorageSystemStackTrace.cpp:131` - the Linux handler rejects stale sequence numbers.
- `src/Storages/System/StorageSystemStackTrace.cpp:582` - if a thread blocks the service signal, the row is emitted with default stack fields instead of waiting indefinitely.
- `contrib/jemalloc-cmake/CMakeLists.txt:1` - jemalloc is disabled under sanitizers except UBSan, which matters for tests and for any expectation of jemalloc samples.
- `src/Interpreters/ThreadStatusExt.cpp:386` - query-local trace-log collection is enabled only when the query setting is true.

Safety contracts:

- `src/Storages/System/StorageSystemStackTrace.cpp:93` - only one table query may run at a time because global variables carry response data.
- `src/Storages/System/StorageSystemStackTrace.cpp:122` - the signal handler forbids allocations.
- `src/Storages/System/StorageSystemStackTrace.cpp:161` - the implementation asserts that the operations used in the handler are signal-safe.
- `src/Storages/System/StorageSystemStackTrace.cpp:185` - pipe wait has a timeout and handles EINTR.
- `src/Storages/System/StorageSystemStackTrace.cpp:381` - signals are sent sequentially to avoid OS queued-signal limits.
- `src/Common/StackTrace.h:26` - StackTrace calculation is signal-safe only after PHDR cache initialization.
- `src/Common/Jemalloc.cpp:104` - the jemalloc allocation sample hook forbids allocations before copying the sampled backtrace.
- `src/Common/TraceSender.cpp:41` - trace sender drops recursive sends.
- `src/Common/TraceSender.cpp:63` - trace pipe writes are constrained to be atomic up to `PIPE_BUF`.

User-facing contracts:

- `docs/en/operations/system-tables/stack_trace.md:16` - the table's purpose is to expose stack traces of all server threads.
- `docs/en/operations/system-tables/stack_trace.md:18` - users should use `addressToLine`, `addressToLineWithInlines`, `addressToSymbol`, and `demangle` for analysis.
- `src/Core/Settings.cpp:3985` - `allow_introspection_functions` is false by default.
- `src/Functions/addressToLine.cpp:24` - `addressToLine` checks access before creation.
- `src/Functions/demangle.cpp:27` - `demangle` also checks access before creation.
- `docs/en/operations/allocation-profiling.md:48` - jemalloc samples can be stored in `system.trace_log`.
- `src/Core/ServerSettings.cpp:1251` - server setting docs connect global jemalloc samples to `system.trace_log`.
- `src/Core/Settings.cpp:7428` - query setting controls per-query jemalloc trace-log sample collection.

Vendored dependency contracts:

- `contrib/llvm-project/libunwind/include/libunwind.h:118` - `unw_backtrace()` is a local ClickHouse libunwind surface, so downstream portability cannot assume stock LLVM/libunwind has it.
- `contrib/llvm-project/libunwind/src/libunwind.cpp:221` - the helper was added for jemalloc; this explains why `jemalloc-cmake` can choose `JEMALLOC_PROF_LIBUNWIND`.
- `contrib/jemalloc/configure.ac:1483` - jemalloc's upstream configure path detects `unw_backtrace` in libunwind when libunwind profiling is enabled.
- `contrib/jemalloc-cmake/CMakeLists.txt:209` - the ClickHouse adapter asserts that its unwind already supports `unw_backtrace`.
- `contrib/jemalloc/src/prof_sys.c:63` - if `JEMALLOC_PROF_LIBUNWIND` is set, jemalloc calls that same symbol.
- `contrib/jemalloc-cmake/CMakeLists.txt:144` - the ClickHouse CMake include tree intentionally overrides generated jemalloc headers, so the build contract is not just upstream configure output.

## Related But Excluded

| Candidate | Why Related | Why Excluded |
|---|---|---|
| `src/Common/QueryProfiler.cpp:242` | QueryProfiler also uses async stack unwinding and PHDR cache. | It writes samples to trace logging/profiler paths, not `system.stack_trace` table reads. |
| `src/Common/SignalHandlers.cpp:119` | The fatal/diagnostic signal handler captures `StackTrace` from `ucontext_t`. | This is the crash reporting path, not the queryable all-thread system table. |
| `src/Interpreters/executeQuery.cpp:823` | Query log stack traces use exception stack string capture. | This is a text exception stack trace for failed queries, not the live thread stack table. |
| `src/Common/ThreadStatus.cpp:126` | `ThreadStatus` sets an alternative signal stack for stack-overflow diagnostics. | The `system.stack_trace` handler installs `SA_SIGINFO` but not `SA_ONSTACK`; this is not a direct prerequisite for the service signal. |
| `src/Common/TraceSender.cpp:33` | TraceSender encodes stack traces for trace-log events, including jemalloc samples. | This is a different producer/consumer path from live `system.stack_trace` reads, but it is covered as an adjacent shared-unwinder path. |
| `src/Common/Jemalloc.cpp:102` | Jemalloc receives profiler backtraces and sends `JemallocSample` trace events. | This is not part of the `system.stack_trace` table read; it is included because it explains why ClickHouse added and uses `unw_backtrace`. |
| `utils/clickhouse-diagnostics/clickhouse-diagnostics:461` | Diagnostics tooling queries `system.stack_trace`. | This is a consumer script, not implementation. |

## Open Questions

- `StorageSystemStackTrace` itself has no visible `hasPHDRCache()` guard. `StackTrace` says signal-safe capture requires a prior `updatePHDRCache()`, while `base/base/phdr_cache.cpp:117` returns a no-op fallback outside the enabled Linux cases. Inference: TSan or non-PHDR builds may still expose the table but with weaker async-signal-safety guarantees. Resolving this would require checking CI build matrices or runtime behavior in those build modes.
- Local evidence for `contrib/jemalloc` shows an upstream `jemalloc/jemalloc` submodule and no dirty working-tree patch in this checkout. The proven ClickHouse-specific surface is `jemalloc-cmake` plus ClickHouse LLVM/libunwind `unw_backtrace()`; proving whether the exact jemalloc commit includes ClickHouse-authored upstreamed changes would require comparing against jemalloc upstream history beyond this shallow/grafted checkout.
- The table relies on global response variables plus a single mutex. That is explicit and intentional, but any future attempt to parallelize reads must redesign the data channel rather than just remove the mutex.
- The tests assert practical success despite an inherent race, not deterministic all-thread completeness. Consumers should treat missing stacks and default rows as expected behavior under thread exit, blocked signal, timeout, or delayed-handler races.

## Validation Checklist

- [x] Every cited file exists.
- [x] Every cited line exists.
- [x] Every major claim has evidence or is marked inference.
- [x] Every discovery matrix axis has findings or an explicit searched-no-hit row.
- [x] External source actions are recorded with destination and commit/tag.
- [x] Every non-standard third-party symbol used by the target was traced to its vendored declaration/implementation or marked unresolved.
