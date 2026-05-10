# Stacktrace Research Report

Generated: 2026-05-10T23:47:47+08:00

## Matrix

```csv
case_id,title,owner,status,project_run,source_mapping,minimal_impl,raw_pc,symbol,file_line,all_native_threads,bthread_or_coroutine,minidump,requires_signal,requires_ptrace,requires_debug_info,requires_frame_pointer,live_api_fit,commands,outputs,blockers,recommendation
clickhouse_system_stack_trace,ClickHouse system.stack_trace + FP/no-FP control,Guava,PASS,PASS,PASS,PASS,yes,yes,yes,yes,no,no,yes,no,yes,no,conditional,in_process_directed_signal_with_local_unwind/clickhouse_system_stack_trace/scripts/run.sh,in_process_directed_signal_with_local_unwind/clickhouse_system_stack_trace/outputs,,Use as in-process directed-signal reference; FP/no-FP remains backend/build control only.
oceanbase_observer_signal_worker,OceanBase observer kill -60 real run,task-18,BLOCKED,BLOCKED,BLOCKED,BLOCKED,unknown,unknown,unknown,unknown,no,no,yes,no,unknown,unknown,conditional,in_process_directed_signal_with_local_unwind/oceanbase_observer_signal_worker/scripts/run.sh,in_process_directed_signal_with_local_unwind/oceanbase_observer_signal_worker/outputs,unclaimed,""
oceanbase_obstack_external,OceanBase OCP obstack_x86_64 vs open-source obstack,task-19,BLOCKED,BLOCKED,BLOCKED,BLOCKED,unknown,unknown,unknown,unknown,no,no,no,yes,yes,unknown,no,external_ptrace_remote_unwind/oceanbase_obstack_external/scripts/run.sh,external_ptrace_remote_unwind/oceanbase_obstack_external/outputs,unclaimed,""
perf_ebpf_vm,perf/eBPF + industry profiling in VM,Papaya,PASS,PASS,PASS,PASS,yes,yes,partial,no,no,no,no,no,yes,yes,no,kernel_perf_ebpf_user_stack/perf_ebpf_vm/scripts/run.sh,kernel_perf_ebpf_user_stack/perf_ebpf_vm/outputs,,"Use as profiling supplement / industry reference only; not an on-demand all-thread snapshot API."
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

- Status: `PASS` as a profiling route.
- Owner: @Papaya
- Task: task #20
- Runtime evidence: `PASS`
- Source evidence: `PASS`
- Minimal implementation: `PASS`
- Minimal defensible conclusion: perf, bpftrace, and Grafana Alloy/Pyroscope eBPF user-stack profiling all run inside the task #16 QEMU VM. They are useful profiling/reference routes, but they are not equivalent to a synchronous on-demand all-thread current stack snapshot.

## Environment

- OS/kernel: Ubuntu 24.04 QEMU guest, Linux `6.8.0-111-generic`.
- VM/container/bare-metal: QEMU/KVM VM from task #16.
- Tool versions: `perf version 6.8.12`, `bpftrace v0.20.2`, Grafana Alloy `v1.16.1`, Docker `29.1.3`.
- Kernel settings/capabilities observed: `perf_event_paranoid=-1`, `kptr_restrict=0`, `unprivileged_bpf_disabled=2`, `perf_event_max_stack=127`, BTF/tracefs/debugfs present.
- Evidence file: `outputs/vm_latest/environment.txt`.

## Project / Release

- Project: Linux perf/eBPF, bpftrace, Grafana Alloy `pyroscope.ebpf`, Grafana Pyroscope.
- Source URL:
  - <https://man7.org/linux/man-pages/man1/perf-record.1.html>
  - <https://man7.org/linux/man-pages/man2/perf_event_open.2.html>
  - <https://grafana.com/docs/alloy/latest/reference/components/pyroscope/pyroscope.ebpf/>
  - <https://grafana.com/docs/pyroscope/latest/get-started/>
- Version/tag: Ubuntu 24.04 guest kernel + distro perf/bpftrace + Grafana Alloy apt package + `grafana/pyroscope:latest`.
- Acquisition method: Ubuntu packages, Grafana apt repo, Pyroscope Docker image.

## Commands

The repo was synced into the running VM as `~/stacktrace-research-repro`. Dependencies were installed in the guest, then each route was run separately:

```bash
cd ~/stacktrace-research-repro/kernel_perf_ebpf_user_stack/perf_ebpf_vm
sudo bash scripts/install_deps.sh
bash scripts/run_perf.sh
sudo bash scripts/run_bpftrace.sh
sudo bash scripts/run_industry_profiler.sh
```

Host-side VM sanity checks used the task #16 contract:

```bash
just vm-wait-ssh
just vm-ssh 'id && uname -r && sysctl kernel.perf_event_paranoid kernel.kptr_restrict'
```

## Outputs

Curated outputs are checked in under `outputs/vm_latest/`:

- `environment.txt`
- `perf_summary.txt`
- `bpftrace_summary.txt`
- `industry_profiler_summary.txt`
- `bpftrace_profile_ustack.stdout`
- `bpftrace_offcpu_sched_switch.stdout`
- `alloy_metrics.prom`
- `alloy.stderr`
- `pyroscope.log`

Large raw perf `.data` and `.script` artifacts are not checked in. The summaries include representative callchains and command outcomes.

## Real Project Run

- Status: `PASS`
- What was actually run:
  - `perf record` child-process FP/DWARF callgraphs for FP and no-FP target binaries.
  - `perf record -p` attach to the running target.
  - `sudo perf record -a` system-wide sampling in the VM.
  - `sudo bpftrace` profile `ustack()` on-CPU sampling.
  - `sudo bpftrace` sched-switch/off-CPU event probe.
  - Grafana Alloy `pyroscope.ebpf` sending profiles to local Pyroscope.
- Target shape: one process with two CPU-running, two sleeping, and two mutex-blocked native threads.
- Key observed outputs:
  - perf FP/DWARF runs produced 792-1187 samples per run.
  - perf system-wide DWARF run produced 797 target samples.
  - perf unique target TIDs were always the two CPU workers, not all six target worker threads.
  - bpftrace `profile:hz` produced 1448 output lines with symbolized user stacks including `target_leaf -> target_level_three -> target_level_two -> target_level_one -> cpu_worker`.
  - bpftrace sched-switch/off-CPU probe produced 227 output lines.
  - Alloy/Pyroscope metrics showed `pyroscope_ebpf_pprof_samples_total=6954`, `pyroscope_ebpf_pprofs_total=3`, `pyroscope_ebpf_pprofs_dropped_total=0`, and `pyroscope_write_sent_profiles_total=3`.

## Source Map

| File | Function/lines | Evidence |
| --- | --- | --- |
| `src/profile_target.cpp` | CPU, sleep, mutex-blocked worker threads | Synthetic target makes profiling semantics auditable. |
| `scripts/run_perf.sh` | FP/DWARF child, attach, system-wide perf runs | Exercises `perf record --call-graph fp/dwarf`. |
| `scripts/run_bpftrace.sh` | `profile:hz` and `sched:sched_switch` | Separates on-CPU sample and off-CPU event evidence. |
| `bpftrace/profile_ustack.bt` | `profile:hz:49 { @[ustack(20)] = count(); }` | Captures user stacks from sampled on-CPU contexts. |
| `bpftrace/offcpu_sched_switch.bt` | `sched:sched_switch` filtered by target comm | Captures event stacks when target threads leave CPU. |
| `alloy/pyroscope_ebpf.alloy.template` | `pyroscope.ebpf` + `pyroscope.write` | Tests industry continuous profiling path against local Pyroscope. |

## Minimal Implementation

- Status: `PASS`
- Path: `src/profile_target.cpp`
- Command: `bash scripts/build_target.sh`
- Output: `build/profile_target_fp`, `build/profile_target_nofp`
- What it proves: the case has a controlled target with CPU-running, sleeping, and blocked native threads.
- What it does not prove: production safety or all-thread snapshot semantics.

## Output Capability

| Capability | Result | Evidence |
| --- | --- | --- |
| raw PC | `yes` | perf/eBPF samples contain instruction pointers and callchains. |
| symbol | `yes` | perf and bpftrace resolve target symbols such as `target_leaf`, `target_level_three`, and `cpu_worker`. |
| file/line | `partial` | Requires debug info and tool-specific reporting; this run focused on symbol/callchain evidence. |
| inline frame | `partial` | perf DWARF path showed inlined `std::thread` frames in the FP binary. |
| native all-thread | `no` | The six-thread target only produced on-CPU perf TIDs for the two CPU workers. |
| selected-thread/process | `partial` | perf `-p` can attach to a process, but it still samples event contexts. |
| coroutine/bthread | `no` | Not runtime-aware. |
| minidump/thread context | `no` | No register/context snapshot format. |

## FP / no-FP Observations

- FP binary + FP callgraph: deep target callchain recovered.
- FP binary + DWARF callgraph: deep target callchain plus some inline frames recovered.
- no-FP binary + FP callgraph: very shallow callchain, typically only `libm -> target_leaf`.
- no-FP binary + DWARF callgraph: better than FP on no-FP binary, but still shallower than FP binary and did not show the full `target_level_three/two/one` chain in this optimized target.

This supports the existing Phase 1 rule: frame pointers remain important for predictable low-overhead stack quality. DWARF helps but is not a drop-in replacement for every optimized binary.

## Safety / Disturbance Boundary

- Signal: no target-process diagnostic signal required for profiling route.
- ptrace: no ptrace in the scripts.
- stop-the-world: no.
- timeout/partial result: sampling windows can miss inactive threads.
- debug info requirement: required for file/line quality.
- frame pointer requirement: required for reliable FP unwinding; DWARF route is separate.
- expected production risk: privileged system-wide profiling, eBPF verifier/tooling compatibility, symbol cache/storage, and sampling overhead.
- dependency note: `install_deps.sh` installs Docker and Grafana Alloy in the VM; task #16 cloud-init already provided a usable perf/bpftrace/just base.

## Boundaries

- This case validates profiling availability, not a synchronous on-demand all-thread current stack snapshot.
- On-CPU profiling sampled CPU-running threads and did not cover the sleeping/mutex-blocked threads as current stacks.
- sched-switch/off-CPU evidence is event-based and historical, not a live stack dump.
- Alloy/Pyroscope eBPF is an industry continuous profiling path; it should not be described as a Doris BE live dump API.

## Blockers

- None for the Phase 1 profiling reproduction.
- Product blocker remains semantic: this route does not satisfy "click once, capture every thread's current stack" by itself.

## Decision

- Recommendation: `PASS_AS_PROFILING_ROUTE_ONLY`
- Reason: VM/root execution proves perf, bpftrace, and Alloy/Pyroscope eBPF user-stack profiling are viable. The same evidence demonstrates why the route is not an on-demand all-thread snapshot API.
- Next step: keep it as an industry profiling/reference lane. Do not promote it to Doris BE live all-thread dump without a separate thread enumeration + trigger + coordination snapshot mechanism.
