# ob-open-obstack-ptrace

## What This Verifies

Open-source `oceanbase/obstack` built from source can perform external ptrace/remote-unwind stack collection.

## Source Trace

release tag: TBD
commit: TBD

```text
TBD src/main.cpp:<line> main
  -> TBD enumerate /proc/<pid>/task
    -> TBD ptrace(PTRACE_ATTACH, tid)
      -> TBD libunwind-ptrace _UPT_create
        -> TBD unw_init_remote
          -> TBD unw_step / unw_get_reg
    -> TBD ptrace(PTRACE_DETACH, tid)
  -> output: raw PC / symbol / aggregated stack result
```

## Run

```bash
just ob-open-obstack-ptrace
```

## Inputs / Outputs

| input | output | meaning |
| --- | --- | --- |
| `commands/attach_synthetic.sh` | `commands/attach_synthetic.out` | Attach to a controlled synthetic target. |
| `commands/attach_observer.sh` | `commands/attach_observer.out` | Attach to real observer if allowed; blocker must be explicit if not. |

## Minimal Impl

`minimal_impl/` must keep ptrace attach, remote unwind, and detach only. It must not claim low-disturbance online suitability.
