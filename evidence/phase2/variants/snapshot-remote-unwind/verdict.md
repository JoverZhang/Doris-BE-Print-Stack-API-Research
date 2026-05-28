# Verdict

Status: hold for production, useful as exploration evidence.

What passed:

- `cmake --build be/build_Release --target doris_be -j 8` passed in `docker.io/apache/doris:build-env-ldb-toolchain-latest`.
- `build.sh --be` reached C++ link/install. The only final warning was root `output/` packaging `cp` permission preservation on the bind mount.
- Signal snapshots ran against a standalone BE. `rt_tgsigqueueinfo` was used for normal delivery; `tgkill` fallback is implemented.
- The signal handler only copies register state and bounded stack bytes. It does not call libunwind, allocate, log, lock, or symbolize.
- JSON responses contain `pc`, `dso`, and `dso_offset`; `api/no-symbol-check.txt` confirms no function/file/line/symbol keys.

What failed or held:

- The thirdparty `libunwind.a` in this image is local-only for address-space creation. `_ULx86_64_create_addr_space` is a null-returning stub, captured in `build-output/libunwind-remote-stub.txt`.
- Because remote libunwind address spaces cannot be created, the implementation falls back to coordinator-side frame-pointer walking over the copied stack snapshot.
- In the idle standalone BE run, the FP fallback did not recover beyond the interrupted PC. 8KiB and 64KiB both produced max 1 frame/thread.
- Full-thread dumps consistently returned root `status=timeout` at 1000ms because a small number of threads did not run the handler before the deadline; most threads still produced raw PC snapshots.

Stack byte comparison:

- See `stack-bytes/result.md`.
- 8KiB: 1871 threads, 1863 ok, 0 multi-frame threads, max depth 1, elapsed 4157ms.
- 64KiB: 1871 threads, 1863 ok, 0 multi-frame threads, max depth 1, elapsed 4185ms.

Recommendation:

Do not ship this variant as the production native stack implementation without either linking a non-stubbed architecture remote libunwind (`libunwind-x86_64` plus generic support) or implementing a real DWARF/EH-frame unwinder over the copied stack snapshot. The snapshot transport and API shape are viable; frame coverage is not.
