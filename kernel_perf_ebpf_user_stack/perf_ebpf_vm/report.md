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
