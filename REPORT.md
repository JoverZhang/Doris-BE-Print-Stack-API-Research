# Stacktrace Research Report

Generated: 2026-05-10T23:26:03+08:00

## Matrix

```csv
case_id,title,owner,status,project_run,source_mapping,minimal_impl,raw_pc,symbol,file_line,all_native_threads,bthread_or_coroutine,minidump,requires_signal,requires_ptrace,requires_debug_info,requires_frame_pointer,live_api_fit,commands,outputs,blockers,recommendation
clickhouse_system_stack_trace,ClickHouse system.stack_trace + FP/no-FP control,Guava,PASS,PASS,PASS,PASS,yes,yes,yes,yes,no,no,yes,no,yes,no,conditional,in_process_directed_signal_with_local_unwind/clickhouse_system_stack_trace/scripts/run.sh,in_process_directed_signal_with_local_unwind/clickhouse_system_stack_trace/outputs,,Use as in-process directed-signal reference; FP/no-FP remains backend/build control only.
oceanbase_observer_signal_worker,OceanBase observer kill -60 real run,task-18,BLOCKED,BLOCKED,BLOCKED,BLOCKED,unknown,unknown,unknown,unknown,no,no,yes,no,unknown,unknown,conditional,in_process_directed_signal_with_local_unwind/oceanbase_observer_signal_worker/scripts/run.sh,in_process_directed_signal_with_local_unwind/oceanbase_observer_signal_worker/outputs,unclaimed,""
oceanbase_obstack_external,OceanBase OCP obstack_x86_64 vs open-source obstack,task-19,BLOCKED,BLOCKED,BLOCKED,BLOCKED,unknown,unknown,unknown,unknown,no,no,no,yes,yes,unknown,no,external_ptrace_remote_unwind/oceanbase_obstack_external/scripts/run.sh,external_ptrace_remote_unwind/oceanbase_obstack_external/outputs,unclaimed,""
perf_ebpf_vm,perf/eBPF + industry profiling in VM,task-20,in_progress,BLOCKED,BLOCKED,BLOCKED,unknown,unknown,unknown,partial,no,no,no,no,yes,yes,no,kernel_perf_ebpf_user_stack/perf_ebpf_vm/scripts/run.sh,kernel_perf_ebpf_user_stack/perf_ebpf_vm/outputs,,""
```

## Reference Checklist

# Reference Checklist

Deferred or component-level techniques:

- gperftools CPU/heap profiler
- libbacktrace
- Boost.Stacktrace
- Folly symbolizer
- Crashpad
- Breakpad
- cooperative safepoint stack collection
- Intel PT / LBR
- language/runtime-specific stacks

## Required Evidence For Promotion

- [ ] Exact project version, release tag, commit, binary version, or build id.
- [ ] Environment recorded: OS, kernel, CPU, VM/container/bare-metal.
- [ ] Reproduction command/script committed.
- [ ] Raw output path recorded under the case directory.
- [ ] Error logs recorded for failed or partial runs.
- [ ] Source files and functions/lines mapped.
- [ ] Real project run clearly separated from minimal implementation.
- [ ] Minimal implementation says what it proves and what it does not prove.
- [ ] Output capability table filled: raw PC, symbol, file/line, inline, all-thread, selected-thread, bthread/coroutine, minidump/context.
- [ ] Safety boundary filled: signal, ptrace, timeout, frame pointer, debug info, disturbance.
- [ ] Status is one of `PASS`, `PARTIAL`, `FAIL`, `BLOCKED`.

## Status Rules

- `PASS`: real project run succeeded; output paths exist; source mapping supports the observed behavior; limitations are documented.
- `PARTIAL`: important evidence exists, but at least one required capability or project path is missing.
- `FAIL`: project or method ran and failed in a meaningful way; failure is documented.
- `BLOCKED`: could not run because of missing access, build failure, VM capability, tool availability, or unclear prerequisite.

## Hard Constraints

- Do not use a minimal implementation as a substitute for real project reproduction.
- Do not call crash/minidump all-thread context a live diagnostic API.
- Do not claim file/line correctness without debug info and demonstrated output.
- Do not claim all-thread support unless actual output proves all target threads or explains omissions.
- Do not claim low disturbance without a measured or bounded disturbance mechanism.

## Case Reports

### in_process_directed_signal_with_local_unwind/clickhouse_system_stack_trace/report.md

# ClickHouse system.stack_trace Phase 1-B Report

## Verdict

PASS.

This case reproduces ClickHouse `system.stack_trace` on the fixed official release `v26.3.10.62-lts` and proves:

- raw stack PC output from a real ClickHouse server;
- symbol output with `addressToSymbol()` and `demangle()`;
- file/line output with matching `clickhouse-common-static-dbg`;
- inline file/line output with `addressToLineWithInlines()`;
- a separate FP/no-FP backend/build-condition control.

The FP/no-FP control is not a ClickHouse API comparison. ClickHouse exposes one SQL table: `system.stack_trace`.

## Run

```bash
just clickhouse
```

Direct case entry:

```bash
in_process_directed_signal_with_local_unwind/clickhouse_system_stack_trace/scripts/run.sh
```

Host prerequisites are ordinary user-space tools: `curl`, `tar`, coreutils checksums, `readelf`/`addr2line`, `g++`, and `libunwind-dev` for the FP/no-FP control.

Large files are cached and gitignored:

- `cache/clickhouse-common-static-26.3.10.62-amd64.tgz`
- `cache/clickhouse-common-static-dbg-26.3.10.62-amd64.tgz`
- `cache/debug-extract/.../clickhouse.debug`
- `bin/clickhouse`
- `bin/clickhouse.debug`
- server `data/`, `tmp/`, `logs/`

## Release and Debug Info

ClickHouse release:

- URL: <https://github.com/ClickHouse/ClickHouse/releases/download/v26.3.10.62-lts/clickhouse-common-static-26.3.10.62-amd64.tgz>
- Size: `221892115` bytes
- SHA256: see `outputs/clickhouse_package.sha256`

Debug package:

- URL: <https://github.com/ClickHouse/ClickHouse/releases/download/v26.3.10.62-lts/clickhouse-common-static-dbg-26.3.10.62-amd64.tgz>
- Size: `833692025` bytes
- SHA256: `78b4c8d19808951d2ee3607a7114fc6e6e94fdc013678093deafeed9af0d20b1`
- Package member: `clickhouse-common-static-dbg-26.3.10.62/usr/lib/debug/usr/bin/clickhouse.debug`
- Case-local layout: `bin/clickhouse.debug` symlink to the extracted debug binary
- Build ID: `6eb1953afad1495bf822a2e45c41166d34390877` for both `clickhouse` and `clickhouse.debug`

The case-local layout works because ClickHouse `SymbolIndex` first checks for a non-empty sibling debug file named after the executable stem: for `bin/clickhouse`, it checks `bin/clickhouse.debug`. The global layouts are still documented for VM/root installs: `/usr/lib/debug/usr/bin/clickhouse.debug` and `/usr/lib/debug/.build-id/<build-id>.debug`.

## Real ClickHouse Output

Summary from `outputs/phase1b_summary.txt`:

```text
version=26.3.10.62
rows:       657
with_trace: 653
min_trace:  0
max_trace:  17
```

Schema from `outputs/system_stack_trace_describe.txt`:

```text
thread_name String
thread_id UInt64
query_id String
trace Array(UInt64)
untracked_memory Int64
```

Raw trace sample from `outputs/raw_trace.txt`:

```text
thread_name:      TCPHandler
query_id:         <non-empty query id>
trace_len:        17
trace_head:       [651059,603036,603788,614504,396512763]
```

Symbol sample from `outputs/symbol_names.txt`:

```text
'DB::PullingAsyncPipelineExecutor::pull(DB::Chunk&, unsigned long)'
'DB::TCPHandler::runImpl()'
```

File/line sample from `outputs/file_lines_filtered.txt`:

```text
./contrib/llvm-project/libcxx/src/condition_variable.cpp:37
./ci/tmp/build/./src/Loggers/OwnSplitChannel.cpp:515
./base/poco/Foundation/src/Thread_POSIX.cpp:356
```

Inline sample from `outputs/inline_lines.txt`:

```text
./ci/tmp/build/./src/Loggers/OwnSplitChannel.cpp:363
./contrib/llvm-project/libcxx/src/condition_variable.cpp:37:std::__1::condition_variable::wait(...)
```

This satisfies the hard file-line/debug-info gate. The first few frames in some rows still resolve to `bin/clickhouse.debug`; later frames resolve to source paths. That is expected for trampoline/signal/unwind frames where source line data is not useful.

## FP/no-FP Controlled Backend Comparison

Command:

```bash
scripts/run_fp_no_fp_control.sh
```
