# ob-kill60 Verdict - Attempt 1

Overall: HOLD plus production policy issue.

What passed:

- C++ build/link passed in `docker.io/apache/doris:build-env-ldb-toolchain-latest`.
- `cmake --build be/build_Release --target doris_be -j 8` passed.
- API contract passed for all required smoke cases: all threads, one tid, busy, timeout, missing tid.
- API frames contain only `pc`, `dso`, and `dso_offset`; no function/file/line/symbol JSON fields were found.
- Coordinator-side DSO offset computation is usable: `correctness/offline-symbolization.txt` resolves API-returned `dso_offset` values back to Doris functions/lines offline.
- Realtime signal delivery worked through `rt_tgsigqueueinfo` for captured worker threads. No tgkill fallback was needed in the smoke run.
- 50-repeat loop had 50 curl successes and no BE container crash.

Why it is held:

- The signal handler calls libunwind to collect raw PCs. It intentionally does not symbolize, allocate, or log in the handler, but libunwind is not async-signal-safe. This fails a production-safety bar for arbitrary-thread interruption.
- Coverage is partial under tight deadlines. The 5000 ms all-thread smoke completed with `status=ok`, 1864 ok threads, 4 signal-blocked threads, and 1 skipped coordinator/self thread. The 1000 ms repeat loop alternated between `ok` and `timeout`; successful curl responses still averaged about 15.7 timed-out threads. This timeout tail is not root-caused and should not be treated as proof that the direction is impossible.
- The coordinator skips the request thread to avoid self-deadlock in the two-phase release protocol, so this variant does not provide a self-thread known-stack chain for the HTTP handler.

Build/packaging note:

- `build.sh` linked and installed `be/output/lib/doris_be`. The final root output copy printed `cp: preserving permissions ... Invalid argument` on executable scripts in the bind mount. This is recorded as a packaging-layer copy warning/failure, not a C++ build failure.

Evidence anchors:

- Build facts: `build-output/compile-flags.txt`, `build-output/linked-libraries.txt`
- API samples: `api/one-tid.json`, `api/busy.json`, `api/timeout.json`, `api/missing-tid.json`, `api/no-symbol-check.txt`
- Correctness: `correctness/build-ids.txt`, `correctness/offline-symbolization.txt`
- Repeat: `repeat/result.md`, `repeat/dump-loop.csv`
- Patch: `../../../../patches/ob-kill60/0001-feature-be-Add-ob-kill60-native-stack-collector.patch`
