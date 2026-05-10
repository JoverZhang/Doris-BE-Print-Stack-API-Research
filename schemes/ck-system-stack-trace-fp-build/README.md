# ck-system-stack-trace-fp-build

## What This Verifies

ClickHouse source build under frame-pointer-preserving build conditions can be compared against the default source build without changing the user-facing `system.stack_trace` API.

## Source Trace

release tag: TBD
commit: TBD

```text
TBD same source path as ck-system-stack-trace-default
  -> output: system.stack_trace trace Array(UInt64)
  -> comparison: default build output vs frame-pointer build output
```

## Run

```bash
just ck-system-stack-trace-fp-build
```

## Inputs / Outputs

| input | output | meaning |
| --- | --- | --- |
| `queries/thread_stack.sql` | `queries/thread_stack.out` | Stack trace output from the source frame-pointer build. |
| `queries/thread_stack_fileline.sql` | `queries/thread_stack_fileline.out` | File/line output from the source frame-pointer build. |

## Minimal Impl

`minimal_impl/` must keep a small frame-pointer walker versus libunwind comparison. It must state that this is a build-condition/backend comparison, not a second ClickHouse user API.
