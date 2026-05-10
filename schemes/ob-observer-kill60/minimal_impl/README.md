# Minimal Impl

This program is a mechanism-only reduction of the OceanBase `kill -60` path:

```text
shell kill -60 <pid>
  -> signal-wait thread catches signal 60 with sigtimedwait
    -> send_request_and_wait writes a request to signal-worker pipe
      -> signal worker opens stack.<pid>.<timestamp>
      -> signal worker writes /proc/self/maps
      -> signal worker enumerates /proc/self/task
      -> signal worker sends SYS_rt_tgsigqueueinfo(..., SIGURG, ...)
        -> target thread signal handler captures local libunwind frames
        -> signal worker writes one "tid/tname/lbt" line per responding thread
```

It intentionally omits OceanBase storage, SQL, election, tenants, deployment,
and logging. It proves only the in-process directed-signal/local-unwind shape.
