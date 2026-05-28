# Minimal Impl

This scheme uses the same controlled target shape as `ebpf-perf-bpftrace`.
The actual C++ fixture lives in `../../../shared/ebpf/profile_target/`:

- two CPU-running worker threads;
- two sleeping worker threads;
- two mutex-blocked worker threads;
- printed Linux TIDs for every role.

The industry profiler should prove sample delivery for the target process, not
live all-thread snapshot semantics. The expected boundary remains
`all_native_threads=no` and `live_api_fit=no`.
