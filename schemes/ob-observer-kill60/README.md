# ob-observer-kill60

## What This Verifies

OceanBase observer built from source can handle `kill -60 <observer_pid>` and emit real observer stack output.

## Source Trace

release tag: TBD
commit: TBD

```text
TBD src/observer/ob_signal_handle.cpp:<line> <signal 60 handler>
  -> TBD src/.../ob_signal_worker.cpp:<line> <send request and wait>
    -> TBD enumerate /proc/self/task
      -> TBD SYS_rt_tgsigqueueinfo(..., SIGURG, ...)
        -> TBD src/...:<line> ObSigBTOnlyProcessor::<method>
          -> TBD src/.../ob_libunwind.c:<line> safe_backtrace
            -> TBD unw_getcontext / unw_init_local / unw_step
  -> output: stack.<pid>.<timestamp> or documented observer stack file
```

## Run

```bash
just ob-observer-kill60
```

## Inputs / Outputs

| input | output | meaning |
| --- | --- | --- |
| `commands/observer_kill60.sh` | `commands/observer_kill60.out` | `kill -60` run against a real source-built observer and normalized stack result. |

## Minimal Impl

`minimal_impl/` must keep signal 60 trigger, thread enumeration, per-thread signal, local unwind, and stack-file output. It must omit OceanBase storage, SQL, election, and cluster concerns.
