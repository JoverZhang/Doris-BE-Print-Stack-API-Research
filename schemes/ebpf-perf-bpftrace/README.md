# ebpf-perf-bpftrace

## What This Verifies

`perf` and `bpftrace` can collect user stack samples in a VM/root-capable environment, but the result is profiling/event evidence, not a synchronous all-native-thread current stack snapshot.

## Source Trace

release tag:
- Runtime guest: Ubuntu 24.04, Linux `6.8.0-111-generic`, `perf version 6.8.12`, `bpftrace v0.20.2`.
- Upstream source trace for perf/kernel: Linux `v6.8.12`, commit `632428373bea`.
- Upstream source trace for bpftrace: `v0.20.2`, commit `b0f7f14`.

commit: runtime binaries come from guest distro packages; upstream file/function/line references below were checked against the release tags above.

dump style: sampled callchain/profile output. It records stacks observed at perf/eBPF events. It does not enumerate all target threads and does not force every target thread to report its current stack.

```text
Upstream perf/perf_event path:
tools/perf/builtin-record.c:3996 cmd_record creates rec->evlist
  -> tools/perf/builtin-record.c:4004 parses record options such as --call-graph
    -> tools/perf/builtin-record.c:4107 initializes symbol handling
      -> tools/perf/util/evsel.c:2152 evsel__open
        -> tools/perf/util/evsel.c:2000 evsel__open_cpu
          -> tools/perf/util/evsel.c:2054 sys_perf_event_open
            -> kernel/events/core.c:12420 SYSCALL_DEFINE5(perf_event_open)
              -> kernel/events/core.c:12447 security_perf_event_open permission gate
                -> kernel/events/core.c:7684 perf_sample_save_callchain for PERF_SAMPLE_CALLCHAIN
                  -> kernel/events/core.c:7628 perf_callchain
                    -> kernel/events/callchain.c:179 get_perf_callchain
                      -> kernel/events/callchain.c:218 perf_callchain_user
                        -> arch/x86/events/core.c:2859 perf_callchain_user
                          -> arch/x86/events/core.c:2876 starts at regs->bp
                            -> arch/x86/events/core.c:2891-2897 reads user frame links and return addresses

Upstream bpftrace profile/ustack path:
src/ast/attachpoint_parser.cpp:216 profile provider dispatch
  -> src/ast/attachpoint_parser.cpp:569 AttachPointParser::profile_parser
    -> src/ast/attachpoint_parser.cpp:584-593 parses profile target/rate
      -> src/attached_probe.cpp:206 ProbeType::profile
        -> src/attached_probe.cpp:1364 AttachedProbe::attach_profile
          -> src/attached_probe.cpp:1398 bpf_attach_perf_event(PERF_TYPE_SOFTWARE, PERF_COUNT_SW_CPU_CLOCK)
            -> src/ast/passes/codegen_llvm.cpp:225 builtin ustack dispatch
              -> src/ast/passes/codegen_llvm.cpp:150 CodegenLLVM::kstack_ustack
                -> src/ast/irbuilderbpf.cpp:1417 IRBuilderBPF::CreateGetStackId
                  -> src/ast/irbuilderbpf.cpp:1428 sets user-stack flag
                    -> src/ast/irbuilderbpf.cpp:1438 emits BPF_FUNC_get_stackid

Local fixture path:
commands/perf_fp.sh:13 perf record -F 99 -e cpu-clock:u --call-graph fp,64
  -> perf_event sampling on CPU-clock user events
    -> sampled target context unwinds user stack with frame pointers
      -> commands/perf_fp.sh:25-43 writes commands/perf_fp.out

commands/perf_dwarf.sh:13 perf record -F 99 -e cpu-clock:u --call-graph dwarf,8192
  -> perf_event sampling on CPU-clock user events
    -> sampled target context unwinds user stack with DWARF/unwind metadata
      -> commands/perf_dwarf.sh:25-43 writes commands/perf_dwarf.out

commands/bpftrace_ustack.bt:1 profile:hz:49
  -> commands/bpftrace_ustack.bt:4 ustack(20)
    -> sampled on-CPU user stack aggregation for the target PID
      -> commands/run_bpftrace_ustack.sh:26-42 writes commands/bpftrace_ustack.out

commands/bpftrace_offcpu.bt:1 tracepoint:sched:sched_switch
  -> commands/bpftrace_offcpu.bt:4 ustack(20)
    -> event-based stack aggregation when matching threads leave CPU
      -> commands/run_bpftrace_offcpu.sh:26-43 writes commands/bpftrace_offcpu.out

minimal_impl/profile_target.cpp:54 cpu_worker
  -> minimal_impl/profile_target.cpp:50 target_level_one
    -> minimal_impl/profile_target.cpp:46 target_level_two
      -> minimal_impl/profile_target.cpp:42 target_level_three
        -> minimal_impl/profile_target.cpp:32 target_leaf
          -> sampled stack symbol sequence in commands/*.out

minimal_impl/profile_target.cpp:63 sleep_worker
minimal_impl/profile_target.cpp:70 mutex_block_worker
  -> printed in target thread inventory
  -> expected negative evidence: not covered by on-CPU samples as current stacks
```

## Run

```bash
just ebpf-perf-bpftrace
```

From a separate worktree, point to an already-created VM helper if needed:

```bash
STACKTRACE_VM_SSH=/path/to/main/vm/ubuntu-24.04/ssh.sh just ebpf-perf-bpftrace
```

## Inputs / Outputs

| input | output | meaning |
| --- | --- | --- |
| `commands/perf_fp.sh` | `commands/perf_fp.out` | perf frame-pointer callgraph evidence on the FP target. |
| `commands/perf_dwarf.sh` | `commands/perf_dwarf.out` | perf DWARF callgraph evidence on the no-FP target. |
| `commands/bpftrace_ustack.bt` | `commands/bpftrace_ustack.out` | bpftrace on-CPU user-stack sampling evidence. |
| `commands/bpftrace_offcpu.bt` | `commands/bpftrace_offcpu.out` | sched-switch event/off-CPU evidence, not a current stack snapshot. |
| `minimal_impl/profile_target.cpp` | `minimal_impl/profile_target.out` | controlled target thread inventory. |

## Minimal Impl

`minimal_impl/` keeps only the source-trace nodes needed to prove the semantic boundary:

- CPU workers with a stable symbol chain: `cpu_worker -> target_level_one -> target_level_two -> target_level_three -> target_leaf`.
- Sleeping and mutex-blocked workers with printed TIDs.
- FP and no-FP build variants.

It omits any all-thread dump mechanism. The expected conclusion is:

```text
PASS = VM/root profiling route reproduced; all_native_threads=no; live_api_fit=no
```
