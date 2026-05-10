# Stacktrace Research Report

Generated: 2026-05-10T23:35:55+08:00

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

Result from `outputs/fp_control/depth_summary.csv`:

```text
case,frame_pointer_depth,libunwind_depth
fp_enabled,6,6
fp_omitted,3,6
```

Interpretation:

- The toy frame-pointer walker loses frames when compiled with `-fomit-frame-pointer`.
- `libunwind` still recovers the same depth in this controlled binary because unwind tables are available.
- This is a backend/build-condition comparison only. It does not mean ClickHouse exposes FP and no-FP variants.

## Source Mapping

Source commit: `e1c11930c28196f954a93287e43c1aa112c8c607`.

Key files:

- `src/Storages/System/StorageSystemStackTrace.cpp`
  - signal is `SIGRTMIN` on Linux;
  - enumerates `/proc/self/task`;
  - sends directed signal with `rt_tgsigqueueinfo`;
  - waits with pipe timeout;
  - writes `trace Array(UInt64)` rows.
- `src/Common/StackTrace.cpp`
  - `StackTrace(const ucontext_t&)` aligns captured frames with signal context;
  - `tryCapture()` uses `unw_backtrace()` on Linux.
- `src/Common/SymbolIndex.cpp`
  - documents DWARF debug-info behavior;
  - looks for sibling `<binary>.debug`, `/usr/lib/debug/<binary>.debug`, and build-id debug files;
  - verifies matching build ID before using separate debug info.

## Boundaries

- This case proves ClickHouse release behavior, not Doris BE behavior.
- It proves file-line output only with matching debug info.
- It does not benchmark latency or perturbation.
- It does not cover coroutine/bthread stacks.
- It does not claim FP/no-FP are ClickHouse user-visible modes.

### kernel_perf_ebpf_user_stack/perf_ebpf_vm/report.md

# perf/eBPF VM + industry profiling route

## Verdict

- Status: `BLOCKED`
- Owner: @Papaya
- Task: task #20
- Runtime evidence: `BLOCKED`
- Source evidence: `PASS`
- Minimal implementation: `PASS`
- Minimal defensible conclusion: guest scripts are ready, but this case must not be promoted until run inside the task #16 QEMU VM as root.

## Environment

- OS/kernel: pending VM run; target is Ubuntu 24.04/22.04 guest.
- CPU: pending VM run.
- VM/container/bare-metal: QEMU/KVM VM.
- Required packages/capabilities: `perf`, `bpftrace`, `g++`, `docker`, Grafana Alloy, root or `CAP_PERFMON`/`CAP_BPF` plus related filesystem access.

## Project / Release

- Project: Linux perf/eBPF, bpftrace, Grafana Alloy `pyroscope.ebpf`, Grafana Pyroscope.
- Source URL:
  - <https://man7.org/linux/man-pages/man1/perf-record.1.html>
  - <https://man7.org/linux/man-pages/man2/perf_event_open.2.html>
  - <https://grafana.com/docs/alloy/latest/reference/components/pyroscope/pyroscope.ebpf/>
  - <https://grafana.com/docs/pyroscope/latest/get-started/>
- Version/tag: guest distro packages plus Grafana apt package.
- Commit/build id: pending VM run.
- Acquisition method: Ubuntu packages, Grafana apt repo, Pyroscope Docker image.

## Commands

After task #16 VM is created and reachable:

```bash
vm/ubuntu-24.04/ssh.sh -- bash kernel_perf_ebpf_user_stack/perf_ebpf_vm/scripts/install_deps.sh
vm/ubuntu-24.04/ssh.sh -- bash kernel_perf_ebpf_user_stack/perf_ebpf_vm/scripts/run_all.sh
```

For individual steps:

```bash
bash scripts/build_target.sh
bash scripts/run_perf.sh
bash scripts/run_bpftrace.sh
bash scripts/run_industry_profiler.sh
```

## Outputs

- Samples:
  - `results/latest/perf_summary.txt`
  - `results/latest/bpftrace_summary.txt`
  - `results/latest/industry_profiler_summary.txt`
- Logs:
  - `results/latest/environment.txt`
  - `results/latest/target_*.log`
  - `results/latest/alloy.stderr`
- Artifacts:
  - `results/latest/*.data`
  - `results/latest/*.script`
  - `results/latest/*.report`
  - `results/latest/alloy_metrics.prom`

## Real Project Run

- Status: `BLOCKED`
- What was actually run: host-side syntax/build validation only; no VM execution yet.
- What output was observed: `profile_target_fp` and `profile_target_nofp` compile locally.
- What failed or was not run: VM root perf/bpftrace/Alloy scripts are pending task #16 VM image and SSH runtime.

## Source Map

| File | Function/lines | Evidence |
| --- | --- | --- |
| `src/profile_target.cpp` | CPU, sleep, mutex-blocked worker threads | Synthetic target makes profiling semantics auditable. |
| `scripts/run_perf.sh` | FP/DWARF child, attach, system-wide perf runs | Exercises `perf record --call-graph fp/dwarf`. |
| `scripts/run_bpftrace.sh` | `profile:hz` and `sched:sched_switch` | Separates on-CPU sample and off-CPU event evidence. |
| `alloy/pyroscope_ebpf.alloy.template` | `pyroscope.ebpf` + `pyroscope.write` | Tests industry continuous profiling path against local Pyroscope. |

## Minimal Implementation

- Status: `PASS`
- Path: `src/profile_target.cpp`
- Command: `bash scripts/build_target.sh`
- Output: `build/profile_target_fp`, `build/profile_target_nofp`
- What it proves: the case has a controlled target with CPU-running, sleeping, and blocked native threads.
- What it does not prove: VM perf/eBPF runtime viability, production safety, or all-thread snapshot semantics.

## Output Capability

| Capability | Result | Evidence |
| --- | --- | --- |
| raw PC | `partial` | perf/eBPF sample stacks can include instruction pointers. |
| symbol | `partial` | Depends on ELF symbols and profiler symbolization. |
| file/line | `partial` | Requires debug info and tool support. |
| inline frame | `partial` | DWARF path may recover inline frames. |
| native all-thread | `no` | Profiling samples do not guarantee all thread coverage. |
| selected-thread | `partial` | perf `-p` can attach to a process; still sampling based. |
| coroutine/bthread | `no` | Not runtime-aware. |
| minidump/thread context | `no` | No register/context snapshot format. |

## Safety / Disturbance Boundary

- Signal: no target-process diagnostic signal required for profiling route.
- ptrace: no ptrace in the scripts; some profilers may need `/proc` read capabilities.
- stop-the-world: no.
- timeout/partial result: sampling windows can miss inactive threads.
- debug info requirement: required for file/line quality.
- frame pointer requirement: required for reliable FP unwinding; DWARF route is separate.
- expected production risk: privileged system-wide profiling, eBPF verifier/tooling compatibility, symbol cache/storage, and sampling overhead.

## Boundaries

- This case validates profiling availability, not a synchronous on-demand all-thread current stack snapshot.
- On-CPU profiling may miss sleeping or blocked threads.
- sched-switch/off-CPU evidence is event-based and historical, not a live stack dump.
- Alloy/Pyroscope eBPF is an industry continuous profiling path; it should not be described as a Doris BE live dump API.

## Blockers

- task #16 VM image/create/start/SSH runtime is not yet executed for this case.
- Docker/Grafana Alloy availability and eBPF verifier behavior must be checked in the guest.

## Decision

- Recommendation: `BLOCKED`
- Reason: scripts are ready, but VM runtime evidence is pending.
- Next step: run `install_deps.sh` and `run_all.sh` through `vm/ubuntu-24.04/ssh.sh`, then update this report with observed PASS/PARTIAL/FAIL data.
