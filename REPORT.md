# Stacktrace Research Report

Generated: 2026-05-10T23:12:40+08:00

## Matrix

```csv
case_id,title,owner,status,project_run,source_mapping,minimal_impl,raw_pc,symbol,file_line,all_native_threads,bthread_or_coroutine,minidump,requires_signal,requires_ptrace,requires_debug_info,requires_frame_pointer,live_api_fit,commands,outputs,blockers,recommendation
clickhouse_system_stack_trace,ClickHouse system.stack_trace + FP/no-FP control,task-17,BLOCKED,BLOCKED,BLOCKED,BLOCKED,unknown,unknown,unknown,unknown,no,no,yes,no,yes,unknown,conditional,in_process_directed_signal_with_local_unwind/clickhouse_system_stack_trace/scripts/run.sh,in_process_directed_signal_with_local_unwind/clickhouse_system_stack_trace/outputs,,""
oceanbase_observer_signal_worker,OceanBase observer kill -60 real run,task-18,BLOCKED,BLOCKED,BLOCKED,BLOCKED,unknown,unknown,unknown,unknown,no,no,yes,no,unknown,unknown,conditional,in_process_directed_signal_with_local_unwind/oceanbase_observer_signal_worker/scripts/run.sh,in_process_directed_signal_with_local_unwind/oceanbase_observer_signal_worker/outputs,unclaimed,""
oceanbase_obstack_external,OceanBase OCP obstack_x86_64 vs open-source obstack,task-19,BLOCKED,BLOCKED,BLOCKED,BLOCKED,unknown,unknown,unknown,unknown,no,no,no,yes,yes,unknown,no,external_ptrace_remote_unwind/oceanbase_obstack_external/scripts/run.sh,external_ptrace_remote_unwind/oceanbase_obstack_external/outputs,unclaimed,""
perf_ebpf_vm,perf/eBPF + industry profiling in VM,task-20,BLOCKED,BLOCKED,BLOCKED,BLOCKED,unknown,unknown,unknown,partial,no,no,no,no,yes,yes,no,kernel_perf_ebpf_user_stack/perf_ebpf_vm/scripts/run.sh,kernel_perf_ebpf_user_stack/perf_ebpf_vm/outputs,unclaimed,""
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
