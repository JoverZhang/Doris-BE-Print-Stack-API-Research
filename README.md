# Stacktrace Research Repro

This repo is a source-build research fixture for stack collection schemes.

The active contract is:

- no release-binary evidence;
- root checklist is the only project matrix;
- no `case.yaml`, `matrix.csv`, `templates/`, or `reference_checklist/`;
- each scheme README starts with a source trace: release tag, function names, file paths, and line numbers;
- each scheme has `minimal_impl/`, derived from the source trace;
- research command output sits next to its input and shares the same prefix: `thread_stack.sql` -> `thread_stack.out`, `perf_fp.sh` -> `perf_fp.out`, `bpftrace_ustack.bt` -> `bpftrace_ustack.out`;
- build, fetch, install, and package-manager logs are not committed as research output.

## Checklist

| done | phase | scheme | project | source-build | source-trace | minimal-impl | runnable-output | status | note |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| no | 1 | `ck-system-stack-trace-default` | ClickHouse | blocked | done | done | blocker + minimal only | blocked | Source build blocked by ClickHouse submodule initialization cost; no release binary evidence used. |
| no | 1 | `ck-system-stack-trace-fp-build` | ClickHouse | blocked | done | done | blocker + minimal only | blocked | Build-condition comparison only; source build blocked by same submodule issue. |
| yes | 1 | `ob-observer-kill60` | OceanBase observer | done | done | done | done | in_review | Source-built `v4.5.0_CE` observer under podman AlmaLinux 8 produced a real `kill -60` stack file; direct host build remains blocked by missing `rpmextract.sh`. |
| no | 1 | `ob-ocp-obstack` | OceanBase/OCP | provenance done | source unavailable | not possible | observer blocked + provenance only | blocked | Official package identifies `obstack 2.0.4`; real observer collection still blocked. |
| no | 1 | `ob-open-obstack-ptrace` | `oceanbase/obstack` | blocked | done | done | blocker + minimal only | blocked | Public repo has no release tags; source build blocked on current host deps. |
| yes | 1 | `ebpf-perf-bpftrace` | Linux perf/bpftrace | target source built | done | done | done | in_review | PASS = VM/root profiling route reproduced; `all_native_threads=no`; `live_api_fit=no`. |
| yes | 1 | `ebpf-industry-profiler` | Alloy/Pyroscope | target source built | done | done | done | in_review | PASS = VM/root profiling route reproduced; `all_native_threads=no`; `live_api_fit=no`. |
| no | later | `gperftools-stacktrace` | gperftools | not started | not started | not started | not started | deferred | Capture backend/component. |
| no | later | `libbacktrace-boost-folly` | common C++ stack libraries | not started | not started | not started | not started | deferred | Current-thread/symbolization components. |
| no | later | `crashpad-breakpad` | crash/minidump tooling | not started | not started | not started | not started | deferred | Crash/minidump semantics, not live dump API. |
| no | later | `cooperative-safepoint` | generic runtime design | not started | not started | not started | not started | deferred | Requires separate design. |
| no | later | `intel-pt-lbr` | hardware tracing | not started | not started | not started | not started | deferred | Profiling/tracing reference only. |

## Layout

```text
repos.lock
repos/
schemes/
  <scheme-id>/
    README.md
    build.sh
    run.sh
    commands/ or queries/
      <input>.sql|sh|bt
      <input>.out
    minimal_impl/
      README.md
      build.sh
      run.sh
      <demo source>
      <demo>.out
scripts/
vm/
```

## Scheme README Contract

Every scheme README must contain only the details needed to verify the scheme:

```text
# <scheme-id>

## What This Verifies
<one sentence>

## Source Trace
release tag: <tag>
commit: <commit>

<file>:<line> <function>
  -> <file>:<line> <function>
    -> <file>:<line> <function>
      -> output: <interface/file/tool output>

## Run
just <scheme-id>

## Inputs / Outputs
| input | output | meaning |

## Minimal Impl
<which source-trace nodes are retained and what is omitted>
```

`source-trace` must be written before `minimal_impl/` is implemented.

## Running

```bash
just --list
just validate
```

VM helpers remain available for eBPF and heavyweight build work:

```bash
just vm-create
just vm-start-bg
just vm-wait-ssh
just vm-ssh 'id && uname -r'
just vm-stop
```

If an environment blocks source build or runtime, report the blocker in the task thread. Do not skip it and do not retry indefinitely. For OceanBase dependency issues, prefer rootless `podman`; do not assume Docker is available.
