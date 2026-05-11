# shared/ebpf/profile_target

Controlled C++ target shared by the eBPF profiling schemes.

It intentionally contains no stack dump implementation. The target only creates
a known thread inventory:

- CPU-running workers with stable symbols:
  `target_level_one -> target_level_two -> target_level_three -> target_leaf`.
- Sleeping workers.
- Mutex-blocked workers.
- Startup output with process pid, main tid, worker role, id, and Linux tid.

Schemes use this fixture to prove profiling semantics and their negative
boundary: sampled profiling output is not a live all-native-thread snapshot.
