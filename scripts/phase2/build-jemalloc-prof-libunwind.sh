#!/usr/bin/env bash
# Reason: rebuild Doris's `libjemalloc_doris.a` against the patched
# `thirdparty/build-thirdparty.sh build_jemalloc_doris()` (which now
# passes `--enable-prof-libunwind`). The wrapper exists because
# several container quirks can't be handled inside the variant patch:
#
#   1. `build-thirdparty.sh` unconditionally resets `TP_DIR` to its own
#      directory (its line `export TP_DIR="${curdir}"`), so the install
#      lands at `${DORIS_REPO}/thirdparty/installed/`, NOT
#      `${DORIS_THIRDPARTY}/installed/`. We sync afterward.
#   2. `download-thirdparty.sh` runs `patch -p0`, which tries to
#      preserve POSIX ACLs on the source file. Rootless containers
#      cannot honor `setxattr(system.posix_acl_*)`, so `patch` exits
#      non-zero and `set -e` aborts the whole pipeline. We pre-apply
#      the upstream patch ourselves and touch `patched_mark` so
#      `download-thirdparty.sh` skips it.
#   3. `cleanup_package_source` in `build-thirdparty.sh` deletes the
#      jemalloc source tree after a successful build, taking
#      `doris_build/config.log` with it. We use a sentinel file in
#      `${DORIS_REPO}/thirdparty/installed/lib/` (host-persistent) to
#      record the md5sum of the build's source tarball — that survives
#      cleanup and tells us whether the cached archive matches the
#      currently-pinned jemalloc version.
#   4. `scripts/in-container` runs `podman run --rm`, so any writes
#      outside the bind-mounted project root (including
#      `/var/local/thirdparty/installed/...`) are destroyed when the
#      container exits. We sync the rebuilt archive from the
#      host-persistent install (inside the project root) into the
#      container's install (where CMake's
#      `THIRDPARTY_DIR=${DORIS_THIRDPARTY}/installed` resolves) on
#      every invocation.
#
# Local: invoked by `scripts/phase2/bootstrap.sh` after applying the
# ck-phdr-unwind variant patches, inside the Doris build container.
# Caller is responsible for the in-container environment; we expect
# `DORIS_THIRDPARTY=/var/local/thirdparty` (the standard container
# layout) and `PROJECT_ROOT` pointing at the bind-mounted host root.
set -euo pipefail

DORIS_REPO="${DORIS_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../repos/source/doris-master" && pwd)}"

# Where build-thirdparty.sh actually operates after its TP_DIR
# override. These paths are inside the Doris worktree (bind-mounted
# from the host), so they persist across `--rm` container runs.
HOST_TP_DIR="${DORIS_REPO}/thirdparty"
HOST_TP_INSTALL="${HOST_TP_DIR}/installed"
HOST_ARCHIVE="${HOST_TP_INSTALL}/lib/libjemalloc_doris.a"
# Sentinel records the md5sum of the jemalloc source tarball that
# produced the cached archive. Survives `cleanup_package_source`
# because it lives in installed/lib/, not src/.
HOST_SENTINEL="${HOST_TP_INSTALL}/lib/.libjemalloc_doris.prof-libunwind"

# Where CMake actually links from. `${DORIS_THIRDPARTY}/installed/`
# is inside the container image, destroyed by `--rm`.
TARGET_INSTALL="${DORIS_THIRDPARTY:-/var/local/thirdparty}/installed"
TARGET_ARCHIVE="${TARGET_INSTALL}/lib/libjemalloc_doris.a"

# 1. Sanity-check: the patched build-thirdparty.sh must be live.
#    Without the patch, the configure runs without
#    `--enable-prof-libunwind` and the resulting archive uses the
#    libgcc backtracer — exactly the regression we are guarding
#    against. The precondition holds when called from `bootstrap.sh`
#    after `git am` of the ck-phdr-unwind patches succeeds.
if ! grep -q -- "--enable-prof-libunwind" "${HOST_TP_DIR}/build-thirdparty.sh"; then
    echo "ck-phdr-unwind jemalloc: ${HOST_TP_DIR}/build-thirdparty.sh is missing the --enable-prof-libunwind patch; refusing to run." >&2
    exit 1
fi

# 2. Source vars.sh for JEMALLOC_DORIS_DOWNLOAD / _NAME / _SOURCE /
#    _MD5SUM. Use HOST_TP_DIR (the same directory build-thirdparty.sh
#    will operate in) so subsequent paths line up with what
#    `build_jemalloc_doris` will actually install to.
export TP_DIR="${HOST_TP_DIR}"
# shellcheck disable=SC1091
source "${HOST_TP_DIR}/vars.sh"

JEMALLOC_PATCH="${HOST_TP_DIR}/patches/jemalloc_hook.patch"
JEMALLOC_SRC_TARBALL="${TP_SOURCE_DIR}/${JEMALLOC_DORIS_NAME}"
JEMALLOC_SRC_TREE="${TP_SOURCE_DIR}/${JEMALLOC_DORIS_SOURCE}"
JEMALLOC_PATCHED_MARK="${JEMALLOC_SRC_TREE}/patched_mark"

# 3. Cache-hit path: sentinel matches current md5sum and the archive
#    exists → sync the archive to the container install and exit.
#    We intentionally do NOT replace the container's stock
#    `installed/include/jemalloc/jemalloc.h` even though we built a
#    fresh one. The rebuilt header differs from the stock by exactly
#    one autoconf-detected feature flag
#    (`#define JEMALLOC_HAVE_ATTR_FORMAT_GNU_PRINTF` vs
#    `/* #undef ... */`) which is a compile-time printf-format
#    annotation only — no ABI effect. Touching jemalloc.h would
#    invalidate ccache for every BE TU that includes it (most of the
#    BE), turning a fast incremental build into a near-full rebuild.
#    Keeping the stock header preserves the ccache hit rate at the
#    cost of one minor compile-time warning attribute the BE never
#    relied on.
if [[ -f "${HOST_SENTINEL}" && -f "${HOST_ARCHIVE}" ]] && \
   [[ "$(cat "${HOST_SENTINEL}" 2>/dev/null)" == "${JEMALLOC_DORIS_MD5SUM}" ]]; then
    # Skip if archive content already matches (e.g., wrapper invoked
    # twice in the same container). `cmp -s` is fast.
    if ! cmp -s "${HOST_ARCHIVE}" "${TARGET_ARCHIVE}"; then
        install -m 0644 "${HOST_ARCHIVE}" "${TARGET_ARCHIVE}"
        echo "ck-phdr-unwind jemalloc: cache hit (md5=${JEMALLOC_DORIS_MD5SUM}); synced ${HOST_ARCHIVE} -> ${TARGET_ARCHIVE}."
    else
        echo "ck-phdr-unwind jemalloc: cache hit (md5=${JEMALLOC_DORIS_MD5SUM}); ${TARGET_ARCHIVE} already in sync."
    fi
    exit 0
fi

# 4. Cache miss. Ensure jemalloc source is unpacked. The container
#    image ships the prebuilt thirdparty install but not source
#    tarballs (those total ~8 GB), so we fetch just jemalloc when
#    absent. URL/name/source-dir come from vars.sh so the harness
#    stays in lockstep with Doris's pinned version.
#    `--no-same-owner` keeps tar from chown'ing to the tarball's
#    stored uid/gid; rootless containers cannot honor that and tar
#    aborts the entire extraction.
mkdir -p "${TP_SOURCE_DIR}"
if [[ ! -d "${JEMALLOC_SRC_TREE}" ]]; then
    if [[ ! -f "${JEMALLOC_SRC_TARBALL}" ]]; then
        echo "Fetching ${JEMALLOC_DORIS_DOWNLOAD}"
        curl -fsSL "${JEMALLOC_DORIS_DOWNLOAD}" -o "${JEMALLOC_SRC_TARBALL}"
    fi
    tar --no-same-owner -xjf "${JEMALLOC_SRC_TARBALL}" -C "${TP_SOURCE_DIR}"
fi

# 5. Apply the substantive edit of `jemalloc_hook.patch` (removing
#    `jemalloc_mangle.h` from the header list in `jemalloc.sh`) and
#    touch `patched_mark` so `download-thirdparty.sh` (invoked
#    transitively by `build-thirdparty.sh`) skips its own patch step.
#    We use `sed` instead of `patch -p0`: rootless containers cannot
#    honor `setxattr(system.posix_acl_*)` and `patch`'s in-place
#    attribute preservation triggers a rollback of the edit when the
#    setxattr call fails, leaving the file unchanged despite the
#    "Hunk succeeded" message. The sed edit doesn't touch attributes
#    and applies cleanly. Idempotent (re-application leaves the
#    already-patched line unchanged).
JEMALLOC_HEADER_SH="${JEMALLOC_SRC_TREE}/include/jemalloc/jemalloc.sh"
if [[ ! -f "${JEMALLOC_PATCHED_MARK}" ]]; then
    sed -i \
        's|jemalloc_protos.h jemalloc_typedefs.h jemalloc_mangle.h ; do|jemalloc_protos.h jemalloc_typedefs.h ; do|' \
        "${JEMALLOC_HEADER_SH}"
    if grep -q "jemalloc_protos.h jemalloc_typedefs.h ; do" "${JEMALLOC_HEADER_SH}"; then
        touch "${JEMALLOC_PATCHED_MARK}"
    else
        echo "ck-phdr-unwind jemalloc: substantive edit of ${JEMALLOC_HEADER_SH} did not apply; the upstream jemalloc_hook.patch shape may have changed. Aborting." >&2
        exit 1
    fi
fi

# 6. Invoke the patched build_jemalloc_doris. `build-thirdparty.sh`
#    treats positional args as the package list (see its `read -r -a
#    packages <<<"${@}"`), so the single-package invocation skips the
#    rest of the pipeline. The patched function aborts on
#    `prof-libunwind != 1`, so reaching the next line means the
#    verify passed. The install lands at `${HOST_ARCHIVE}` because
#    build-thirdparty.sh resets TP_DIR to its own directory.
echo "ck-phdr-unwind jemalloc: invoking build-thirdparty.sh jemalloc_doris"
bash "${HOST_TP_DIR}/build-thirdparty.sh" jemalloc_doris

# 7. Cache the build (sentinel records md5sum so future runs can hit)
#    and sync the archive to the container install where CMake links
#    from. As above, the stock `installed/include/jemalloc/jemalloc.h`
#    is intentionally left in place — the rebuilt one differs by a
#    cosmetic feature flag and replacing it would void ccache for
#    every BE TU including jemalloc.h.
echo -n "${JEMALLOC_DORIS_MD5SUM}" > "${HOST_SENTINEL}"
install -m 0644 "${HOST_ARCHIVE}" "${TARGET_ARCHIVE}"
echo "ck-phdr-unwind jemalloc: build complete; cached (md5=${JEMALLOC_DORIS_MD5SUM}) and synced to ${TARGET_ARCHIVE}."
