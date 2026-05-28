# ck-phdr-unwind Verdict - Attempt 1

`ck-phdr-unwind` is buildable and runnable as a Phase 2 exploration variant. Under `evaluation-protocol.md`, it is a production policy fail if handler-side libunwind is forbidden.

## Result

- Variant head: `d7394889fc2689a3c5bd9189d5976fbe8e335a1a`
- Patch: `../../../../patches/ck-phdr-unwind/0001-feature-be-Add-ck-phdr-unwind-native-stack-collector.patch`
- Required target build: pass
- `build.sh --be`: C++ compile/link/install pass; final root output packaging failed because `cp -p` could not preserve permissions on the bind mount.
- Runtime smoke: pass on host port `18043`
- Repeat: 50/50 dumps returned `status=ok`; BE stayed healthy after the loop.
- API symbol contract: pass; responses contain `pc`, `dso`, and `dso_offset`, and no `symbol`, `symbol_name`, `function`, `file`, or `line` keys.

## Observed Behavior

- All-thread dump captured 1871 threads: 1867 `ok`, 4 `signal_blocked`.
- Signaling used `rt_tgsigqueueinfo` for all captured threads; blocked threads were detected from `/proc/self/task/<tid>/status` and not signaled.
- `phdr_cache` metadata records a `dl_iterate_phdr` preflight with 13 objects and 13 executable segments, plus `UNW_CACHE_GLOBAL` configured successfully for libunwind.
- Offline symbolization of returned Doris DSO offsets resolves to expected frames, including `doris::NativeStackAction::handle`.

## Safety Notes

- The collector intentionally runs libunwind from a POSIX signal handler. This is not proven async-signal-safe.
- The PHDR/cache preflight reduces one class of lazy loader/cache surprises but does not prove libunwind cannot allocate, take locks, or touch internal caches for unseen PCs.
- The evidence run did not crash or hang, but absence of failure in smoke tests
  is not a signal-safety proof. Source-level proof plus stress evidence would
  be needed to challenge the policy gate.

## Linker Finding

The first build linked against `/var/local/thirdparty/installed/lib64/libunwind.a` but emitted undefined `_Ux86_64_*` references. That archive provides local-only `_ULx86_64_*` symbols. Defining `UNW_LOCAL_ONLY` before including `libunwind.h` fixed the ABI prefix mismatch; the subsequent `cmake --build be/build_Release --target doris_be -j 8` passed.
