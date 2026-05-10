# Minimal Impl

This is the controlled source target used by the perf/bpftrace scheme.

It preserves the nodes needed by the Source Trace:

- `target_level_one -> target_level_two -> target_level_three -> target_leaf`
  creates a recognizable CPU-running user stack.
- `sleep_worker` creates sleeping threads.
- `mutex_block_worker` creates mutex-blocked threads.
- The startup output prints every Linux TID and role, so profiling output can be
  compared against the full thread set.

It intentionally omits any all-thread dump implementation. That omission is the
control: perf/bpftrace samples should be judged against a known six-worker
target, and the expected boundary is `all_native_threads=no`.
