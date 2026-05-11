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
| yes | 1 | `ck-system-stack-trace-default` | ClickHouse | done | done | done | done | in_review | Source-built `v26.3.10.62-lts` default binary produced raw/symbol/file-line `system.stack_trace` outputs; requires all submodules plus Rust `nightly-2025-07-07`; Build ID `1a71bc7bc6667f8d465ff4ae3cb2bfb2549b39b1`. |
| yes | 1 | `ck-system-stack-trace-fp-build` | ClickHouse | done | done | done | done | in_review | Source-built frame-pointer-preserving build produced raw/file-line `system.stack_trace` outputs; build-condition comparison only, not a second API; Build ID `073c6b8cde9d6091654051d6c7d333928a749e22`. |
| yes | 1 | `ob-observer-kill60` | OceanBase observer | done | done | done | done | in_review | Source-built `v4.5.0_CE` observer under podman AlmaLinux 8 produced a real `kill -60` stack file; direct host build remains blocked by missing `rpmextract.sh`. |
| yes | 1 | `ob-ocp-obstack` | OceanBase/OCP | provenance done | source unavailable | not possible | done | in_review | Official `obstack 2.0.4` package collected real stacks from the source-built `v4.5.0_CE` observer; requires ptrace-capable podman runtime. |
| yes | 1 | `ob-open-obstack-ptrace` | `oceanbase/obstack` | done | done | done | done | in_review | Public source commit built under podman CentOS 7; synthetic attach and real source-built observer attach both PASS. Host Arch build remains blocked by upstream deps profile support. |
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
shared/
  <project>/
    <fixture/helper scripts>
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

`shared/` contains helper code only. It is not a scheme namespace and entries
under it do not appear in the checklist.

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
