# Execution Plan - Rewrite `patches/ck-phdr-unwind/`

> Temporary file. Delete when `patches/ck-phdr-unwind/` exports cleanly,
> round-trips via `just phase2-verify ck-phdr-unwind`, and the three test
> modes (`asan`, `release`, `tsan`) return green.
>
> Source of truth: [docs/design/ck.md](docs/design/ck.md).
> Variant-agnostic contract: [docs/architecture.md](docs/architecture.md).
> Test cases: [docs/phase2-test-plan.md](docs/phase2-test-plan.md).
> Workflow rules: [AGENTS.md](AGENTS.md). Container-only: every `git`,
> `cmake`, `ninja`, `be/build.sh`, `run-be-ut.sh` call goes through
> `just phase2-*`.

## Decisions in scope

1. Override libc `dl_iterate_phdr` with a lock-free walk over the cached
   PHDR list, in `be/src/common/phdr_cache.cpp`.
2. Call `updatePHDRCache()` in `be/src/service/doris_main.cpp` before
   `BackendOptions::init`.
3. `capture_into_slot` returns `CaptureFailed` with zero frames when
   `hasPHDRCache()` is false.
4. Seed the unwind cursor from the interrupted `ucontext_t` with
   `unw_init_local2(&cursor, &ctx, UNW_INIT_SIGNAL_FRAME)`.
5. Define `UNW_LOCAL_ONLY` before `<libunwind.h>` in the variant TU.
6. Link a `libjemalloc_doris.a` configured with `--enable-prof-libunwind`.
   One configuration; no opt-out flag. Helper verifies
   `backtrace_method = 'libunwind'` in `config.log` and aborts on mismatch.
7. Acceptance verification mirrors fp-walk: three `just phase2-test
   new-ut ck-phdr-unwind {asan|release|tsan} "*"` commands.
   `phase2-acceptance.md` is human-owned and currently fp-walk-only; do
   not edit it. Report success to the user as informal Gate satisfaction.
8. The jemalloc helper runs from `phase2-bootstrap` after variant
   patches apply. Idempotent: skip when the archive is present. The
   archive lives at the project-root `.tmp/jemalloc-prof-libunwind/`,
   which `phase2-reset` does not touch (`reset.sh` operates only inside
   `$DORIS_REPO`). One run per project clone in practice.

## Phase A - Clear stale patches and create empty variant branch

Old `patches/ck-phdr-unwind/0003-*.patch` targets `native_stack_collect.cpp`,
which does not exist on `phase2/common`. With the stale patches present
bootstrap fails for this variant; with the patch dir empty bootstrap
also marks it `broken` because `git am ""*.patch` errors. Create the
variant branch manually until exported patches replace the gap.

- [ ] Delete the four files under `patches/ck-phdr-unwind/`.
- [ ] `just phase2-reset` to drop existing `phase2/*` branches.
- [ ] `just phase2-bootstrap`. The summary will list `ck-phdr-unwind` in
      `broken`. Ignore that line; the other variants land normally.
- [ ] `just phase2-shell`. Inside the container, in the doris-master
      tree, run `git switch -c phase2/ck-phdr-unwind phase2/common` to
      create the variant branch from common.
- [ ] `just phase2-status` to confirm `phase2/ck-phdr-unwind` exists
      with zero commits ahead of `phase2/common`.

## Phase B - PHDR override and populate (2 commits)

Two logical changes, two commits. Stay in `phase2-shell`; never run
`git` on the host.

- [ ] On `phase2/ck-phdr-unwind`, edit `be/src/common/phdr_cache.cpp` to
      enable the `extern "C" int dl_iterate_phdr(...)` lock-free override.
      Match the shape in [docs/design/ck.md](docs/design/ck.md) "Shape".
      Comment block: `Reason:` + `Reference: <ck>/base/base/phdr_cache.cpp:57-75.`
      per [docs/coding-guidelines.md](docs/coding-guidelines.md).
- [ ] Commit 1: subject `(be) ck-phdr-unwind enable lock-free dl_iterate_phdr override`.
- [ ] Edit `be/src/service/doris_main.cpp` to call `updatePHDRCache()`
      before `BackendOptions::init`. Comment: `Reason:` +
      `Spec: docs/design/ck.md "Decisions".`
- [ ] Commit 2: subject `(be) ck-phdr-unwind populate PHDR cache at BE startup`.

## Phase C - Variant capture TU (1 commit)

- [ ] Create `be/src/service/http/action/print_stack_ck_phdr_unwind.cpp`
      with the body from [docs/design/ck.md](docs/design/ck.md) "Shape":
  - [ ] `UNW_LOCAL_ONLY` before `<libunwind.h>`.
  - [ ] Includes: `<libunwind.h>`, `<ucontext.h>`, `<cstring>`,
        `common/phdr_cache.h`, `service/http/action/print_stack_capture.h`,
        `service/http/action/print_stack_globals.h`.
  - [ ] TU-local `walk_signal_frame(const ucontext_t&, uintptr_t*, size_t) -> size_t`.
  - [ ] `capture_into_slot` body: default to `CaptureFailed`,
        `hasPHDRCache` gate, call helper, set `frame_count` and `OK`.
- [ ] Confirm `file(GLOB_RECURSE *.cpp)` in
      `be/src/service/CMakeLists.txt:24` picks the new TU up (no
      CMakeLists edit needed).
- [ ] Commit 3: subject `(be) ck-phdr-unwind libunwind capture_into_slot`.

## Phase D - Jemalloc artifacts (1 commit)

- [ ] Create `be/cmake/build-jemalloc-prof-libunwind.sh`. The script:
  - [ ] Fetches `jemalloc-${JEMALLOC_VERSION}` (matches the pin in
        `thirdparty/vars.sh`).
  - [ ] Configures with `--enable-prof`, `--enable-prof-libunwind`,
        `--with-jemalloc-prefix=je`, `--with-install-suffix=_doris`,
        `--disable-cxx`, `--disable-libdl`, `--disable-shared`.
  - [ ] Builds and installs under `.tmp/jemalloc-prof-libunwind/install/`.
  - [ ] Verifies `^backtrace_method = 'libunwind'` in `config.log`;
        aborts on mismatch.
  - [ ] Idempotent: if
        `.tmp/jemalloc-prof-libunwind/install/lib/libjemalloc_doris.a`
        already exists, skip with a one-line message.
- [ ] Edit `be/cmake/thirdparty.cmake`: under `USE_JEMALLOC`, import
      `libjemalloc_doris.a` from
      `${CMAKE_SOURCE_DIR}/.tmp/jemalloc-prof-libunwind/install/lib/`.
      No CMake option. The block must `message(FATAL_ERROR ...)` with
      the exact helper command if the archive is missing.
- [ ] Commit 4: subject `(be) ck-phdr-unwind build-system jemalloc with libunwind backtracer`.

## Phase E - First build and test

The harness wiring is added later in Phase G. For this first pass the
helper runs manually.

- [ ] Inside `phase2-shell`, run `./be/cmake/build-jemalloc-prof-libunwind.sh`
      from the doris-master tree to populate
      `.tmp/jemalloc-prof-libunwind/`.
- [ ] `just phase2-test new-ut ck-phdr-unwind asan "*"`.
- [ ] `just phase2-test new-ut ck-phdr-unwind release "*"`.
- [ ] `just phase2-test new-ut ck-phdr-unwind tsan "*"`.

## Phase F - Export and round-trip verify

- [ ] `just phase2-export ck-phdr-unwind`. Filenames derive from commit
      subjects. Confirm four `.patch` files under
      `patches/ck-phdr-unwind/`.
- [ ] `just phase2-verify ck-phdr-unwind` to confirm the exported
      patches re-apply on `phase2/common` and produce the same tree.
      Note: verify re-applies patches to a fresh worktree and rebuilds;
      it will need the jemalloc archive too. The archive in `.tmp/`
      from Phase E remains in place.

## Phase G - Wire jemalloc helper into `phase2-bootstrap`

This is a parent-repo change to harness code, not a Doris patch. The
edit lives at `scripts/phase2/bootstrap.sh`, not in `patches/`.

- [ ] Edit `scripts/phase2/bootstrap.sh`: inside the variant loop
      (around lines 33-44), after a successful `git am` for
      `ck-phdr-unwind`, check whether
      `${PROJECT_ROOT}/.tmp/jemalloc-prof-libunwind/install/lib/libjemalloc_doris.a`
      exists. If missing, invoke
      `${DORIS_REPO}/be/cmake/build-jemalloc-prof-libunwind.sh` from the
      doris-master tree. Echo a one-line status either way.
- [ ] Validate cache-hit path: `just phase2-reset` then
      `just phase2-bootstrap`. The reset preserves `.tmp/`, so the
      helper should report "already built" and exit fast. `ck-phdr-unwind`
      should now appear in `clean`.
- [ ] Validate cold-build path: `rm -rf .tmp/jemalloc-prof-libunwind/`,
      then `just phase2-reset` and `just phase2-bootstrap`. The helper
      runs and rebuilds the archive.
- [ ] Re-test one mode end-to-end: `just phase2-test new-ut ck-phdr-unwind asan "*"`.
- [ ] Commit on the parent repo (NOT on the doris submodule). Subject
      e.g. `phase2/bootstrap: build jemalloc with libunwind backtracer for ck-phdr-unwind`.

## Verify

- [ ] Three test commands in Phase E return green.
- [ ] `just phase2-verify ck-phdr-unwind` returns success.
- [ ] `patches/ck-phdr-unwind/` contains four `.patch` files.
- [ ] End-to-end cache-hit and cold-build paths in Phase G both succeed.

## Cleanup

- [ ] Delete `EXECUTION_PLAN.md`.
- [ ] Report the new patch list and the harness change back to the user.

## Things to watch for

- `phase2-acceptance.md` is human-owned and currently fp-walk-only. Do
  not edit it. Report green to the user; treat the three commands as an
  informal Gate.
- `phase2-test-plan.md` describes three test cases (`ContractJsonShape`,
  `ThreadIdSelector`, `BestEffortFrameObserved`). They are
  variant-agnostic at the HTTP/JSON level, so the same cases run for
  ck-phdr-unwind through the common library's test fixture
  (`be/test/service/http/print_stack_action_test.cpp`). No variant test
  file is added.
- The Doris libunwind archive (`thirdparty.cmake:89` → `lib64/libunwind.a`)
  already exports the `_ULx86_64_*` family — `stack_trace.cpp:303`
  calls `unw_backtrace`. If linking fails on `unw_init_local2`, check
  `nm` on the archive inside the container.
- `jemalloc/jemalloc#2504`: `--enable-prof-libunwind` can silently fall
  back to libgcc. The verify step in the helper is the only safety net;
  do not skip it.
- `phase2-reset` operates only inside `$DORIS_REPO`. The project-root
  `.tmp/` survives. To force a fresh jemalloc rebuild, also
  `rm -rf .tmp/jemalloc-prof-libunwind/`.
- Phase A manually creates `phase2/ck-phdr-unwind` because bootstrap
  drops the variant from `broken` when its patch dir is empty. After
  Phase F exports real patches, bootstrap creates the branch on its
  own — Phase G validates that.
- Source aliases and comment shape follow
  [docs/coding-guidelines.md](docs/coding-guidelines.md). `Reason:` +
  one of `Spec:` / `Reference:` / `Local:`. Use `<ck>` for citations
  into `repos/source/ClickHouse-v26.3.10.62-lts`.
