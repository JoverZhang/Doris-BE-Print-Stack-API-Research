# Doris BE Print Stack API Research

[Doris#62497](https://github.com/apache/doris/issues/62497)

## 1. Goal

Research practical approaches to dump live stacks of `doris_be` with:

- low latency impact
- second / sub-second level completion target
- no or minimal crash risk
- acceptable stack trace accuracy

This repository is an investigation workspace for first-stage research. It is not
a final design proposal yet.

Related sampled profiling notes are tracked separately in
[PROFILING.md](./PROFILING.md).

## 2. Current Status

| Area | Status |
| --- | --- |
| ClickHouse `system.stack_trace` | Built and reproduced from source; on-demand current-thread snapshot API. |
| OceanBase `kill -60` | Built and reproduced from source; raw stack file plus offline symbolized sample. |
| OceanBase `faststack()` / `obstack` | Source path inspected; `obstack` attach run reproduced; ptrace remote unwind path. |
| signal-handler unwind demo | Runnable minimal prototype. |
| stack-snapshot hybrid demo | Runnable minimal prototype. |
| performance / stability verification | Not started. |

## 3. Reference Taxonomy

This repository's main scope is on-demand current stack dump.

The important correction is that OceanBase `kill -60` and `obstack` are not one
single path. OceanBase currently has at least two distinct stack collection
paths:

- `kill -60 <observer_pid>`: in-process observer signal-worker path. It
  enumerates observer threads, sends directed `SIGURG`, unwinds locally in the
  target thread, and writes a raw `stack.<pid>.<time>` file.
- `faststack()` / `obstack`: OceanBase internal exceptional paths can execute
  the external `obstack` binary. `obstack` enumerates `/proc/<pid>/task`,
  attaches with `ptrace`, performs remote unwind, then symbolizes and aggregates.

| System | Path | Trigger | Capture model | Output | ptrace | Fit for Doris live dump |
| --- | --- | --- | --- | --- | --- | --- |
| ClickHouse | `system.stack_trace` | `SELECT * FROM system.stack_trace` | in-process table enumerates tasks, sends directed service signal, target threads local-unwind | SQL rows with raw `trace`; symbols/file-lines via introspection functions | no | primary reference |
| OceanBase | `kill -60` | `kill -60 <observer_pid>` | observer signal worker sends directed `SIGURG`; target threads local-unwind | `stack.<pid>.<time>` raw addresses; offline symbolization in this repo | no | primary reference |
| OceanBase | `faststack()` / `obstack` | internal `faststack()` triggers or `obstack <pid>` CLI | external process attaches each thread and remote-unwinds with libunwind ptrace backend | symbolized and aggregated stacks | yes | heavy diagnostic reference |

### Chronology

| Item | Public evidence in this workspace |
| --- | --- |
| ClickHouse `system.stack_trace` | Commit `e0000bef989a7fff327f22e8cf4e4443e0e45dff`, 2019-12-22, "Added system.stack_trace table". |
| OceanBase `kill -60` | Present in the public initial OceanBase import `cea7de1475674a82a317f7f550d141c6096d487e`, 2021-05-31. |
| OceanBase `faststack()` calling `obstack` | Present in public OceanBase commit `d627936f7ddd11761189f3d72e5fa729094f24c3`, 2023-06-05. |
| Open-source `oceanbase/obstack` ptrace CLI | Public source import `d91edd6d882a33b69164f8d3e809092408da3a33`, 2024-07-05. |

Interpretation: OceanBase `kill -60` predates the public `faststack()` /
`obstack` integration. The open-source `obstack` ptrace code is later than both
OceanBase `kill -60` and ClickHouse `system.stack_trace`.

## 4. Candidate Directions

### Direction A: unwind in signal handler

Basic idea:

- Coordinator sends signal to target threads.
- Target threads enter a signal handler.
- The handler performs local unwind and records stack PCs.

References:

- ClickHouse `system.stack_trace`
- OceanBase `kill -60`

Main open question:

- Whether unwind inside a signal handler can be made safe enough for Doris BE.
- Need to verify async-signal-safety risk, latency, and failure containment.

### Direction B: stack snapshot hybrid

Basic idea:

- Coordinator sends signal to target threads.
- Signal handler captures only minimal thread state:
  - `ucontext`
  - registers
  - bounded stack snapshot
- Coordinator thread later tries to unwind or reconstruct stack trace from the
  captured data.

Main open question:

- Whether this can reconstruct accurate enough stack traces.
- Need to verify implementation complexity, performance, and correctness.

## 5. Next Steps

1. Stress test the signal-handler unwind demo under allocation, lock, and high
   concurrency scenarios.
2. Verify whether the stack-snapshot hybrid can produce usable symbolized stacks.
3. Measure latency and pause impact for ClickHouse-style and OceanBase-style
   directed-signal collection.
4. Decide whether Doris should use direct signal-handler unwind, a snapshot
   hybrid, or a two-tier design with a lightweight online path plus heavier
   external diagnostic tools.
