# Expected Output Shape

This file describes what should be present after running inside the VM. It is
not a substitute for runtime evidence.

## `environment.txt`

Expected fields:

```text
perf=perf version ...
bpftrace=bpftrace v...
alloy=...
docker=...
perf_event_paranoid=-1
unprivileged_bpf_disabled=...
btf_vmlinux=readable
tracefs=present
```

## `perf_summary.txt`

Expected evidence:

- FP binary + FP callgraph: deep user callchain with
  `target_leaf -> target_level_three -> target_level_two -> target_level_one -> cpu_worker`.
- no-FP binary + FP callgraph: shallower or broken callchain.
- no-FP binary + DWARF callgraph: better recovery than FP if debug/unwind info is available.
- system-wide case: succeeds only in VM/root/capable environment.

## `bpftrace_summary.txt`

Expected evidence:

- `profile_ustack` produces user stacks for CPU-running target threads.
- `offcpu_sched_switch` can show sched-switch event stacks, useful for off-CPU evidence.
- These are event samples, not all-thread snapshots.

## `industry_profiler_summary.txt`

Expected evidence:

- local Pyroscope is ready on `127.0.0.1:4040`.
- Alloy starts with `pyroscope.ebpf`.
- Alloy metrics include `pyroscope_ebpf_*` and/or
  `pyroscope_write_sent_profiles_total`.

If this file records BPF verifier/capability errors, classify the result as a
VM/tooling blocker, not as an inherent industry-route no-go.
