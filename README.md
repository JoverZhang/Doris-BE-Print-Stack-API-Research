# Doris BE Live Stack Dump Research

## 1. Goal

Research practical approaches to dump live stacks of `doris_be` with:

- low latency impact
- second / sub-second level completion target
- no or minimal crash risk
- acceptable stack trace accuracy

This repository is only an investigation workspace for the first-stage research.
It is not a final design proposal yet.

## 2. Current Status

| Area | Status |
|---|---|
| ClickHouse stack trace path | Built / partially inspected |
| OceanBase kill -60 path | Built / not fully inspected |
| obstack | Built / ptrace-based, not the main live-dump direction for now |
| signal-handler unwind demo | Runnable minimal prototype |
| stack-snapshot hybrid demo | Runnable minimal prototype |
| performance / stability verification | Not started |

## 3. Initial Observation

The current investigation mainly compares existing implementations and tries to identify a feasible direction for Doris BE.

Current references:

- ClickHouse stack trace implementation
- OceanBase `kill -60` related implementation
- obstack

Initial note:

- `obstack` is based on `ptrace`, so it is not very aligned with the target scenario here, which is a low-impact live dump mechanism inside / near the running BE process.
- ClickHouse and OceanBase are more relevant references for the next step, especially around signal-triggered stack collection.

## 4. Candidate Directions

At this stage, there is no final recommendation yet. The current investigation is mainly split into two possible directions.

### Direction A: unwind in signal handler

Basic idea:

- Coordinator sends signal to target threads.
- Target threads enter signal handler.
- The handler performs unwind and collects stack trace.

Reference:

- ClickHouse-style stack trace path
- OceanBase `kill -60` path, still needs deeper reading

Main open question:

- Whether unwind inside signal handler can be made safe enough.
- Need to verify async-signal-safety risk, performance, and stability.

### Direction B: stack snapshot hybrid

Basic idea:

- Coordinator sends signal to target threads.
- Signal handler only captures minimal thread state:
  - `ucontext`
  - registers
  - bounded stack snapshot
- Coordinator thread later tries to unwind / reconstruct stack trace from the captured data.

Main open question:

- Whether this can reconstruct accurate enough stack traces.
- Need to verify implementation complexity, performance, and correctness.

## 5. Next Steps

1. Continue reading ClickHouse and OceanBase implementations.
2. Understand how OceanBase handles `kill -60` and unwind safety.
3. Stress test the signal-handler unwind demo.
4. Verify whether stack-snapshot hybrid can produce usable stack traces.
5. Compare the two directions by accuracy, latency impact, crash risk, and implementation complexity.
