#!/usr/bin/env bash
# Reason: rebuild Doris's `libjemalloc_doris.a` against the patched
# `build_jemalloc_doris()`. Four container quirks are handled here so
# the variant patch in build-thirdparty.sh stays minimal:
#
#   1. `build-thirdparty.sh` resets `TP_DIR` to its own directory, so
#      the install lands at `${DORIS_REPO}/thirdparty/installed/`; we
#      sync the archive to the container's CMake-visible install.
#   2. `download-thirdparty.sh` runs `patch -p0`, which sets POSIX ACLs
#      on the source file. Rootless containers cannot honor that and
#      `patch` aborts; we pre-apply via `sed` and touch `patched_mark`.
#   3. `cleanup_package_source` deletes the jemalloc source tree on
#      success, taking `config.log` with it. A sentinel under
#      `installed/lib/` records the source tarball's md5sum so future
#      runs can hit the cache.
#   4. `scripts/in-container` uses `podman run --rm`, so writes outside
#      the bind-mounted project root are destroyed on exit. We cache in
#      `${DORIS_REPO}/thirdparty/installed/` and sync to the container's
#      `${DORIS_THIRDPARTY}/installed/` on every invocation.
#
# Local: invoked by `scripts/phase2/bootstrap.sh` and
# `scripts/phase2/test.sh` inside the Doris build container.
set -euo pipefail

DORIS_REPO="${DORIS_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../repos/source/doris-master" && pwd)}"

# Reason: `build-thirdparty.sh` operates in its own directory after
# `export TP_DIR="${curdir}"` at its top, so the install lands here.
HOST_TP_DIR="${DORIS_REPO}/thirdparty"
HOST_TP_INSTALL="${HOST_TP_DIR}/installed"
HOST_ARCHIVE="${HOST_TP_INSTALL}/lib/libjemalloc_doris.a"
# Reason: sentinel keys the cache on the jemalloc source tarball's
# md5sum. Lives in `installed/lib/` so `cleanup_package_source`
# (which only deletes `src/`) leaves it intact.
HOST_SENTINEL="${HOST_TP_INSTALL}/lib/.libjemalloc_doris.prof-libunwind"

# Reason: CMake links from `${DORIS_THIRDPARTY}/installed/`, which is
# inside the container image and destroyed by `--rm`. We sync per run.
TARGET_INSTALL="${DORIS_THIRDPARTY:-/var/local/thirdparty}/installed"
TARGET_ARCHIVE="${TARGET_INSTALL}/lib/libjemalloc_doris.a"

# 1. Refuse to run unless the patched build-thirdparty.sh is in place.
if ! grep -q -- "--enable-prof-libunwind" "${HOST_TP_DIR}/build-thirdparty.sh"; then
    echo "phase2-jemalloc: ${HOST_TP_DIR}/build-thirdparty.sh is missing the --enable-prof-libunwind patch; refusing to run." >&2
    exit 1
fi

# 2. Source vars.sh for the jemalloc pin (URL, name, source dir, md5).
export TP_DIR="${HOST_TP_DIR}"
# shellcheck disable=SC1091
source "${HOST_TP_DIR}/vars.sh"

JEMALLOC_PATCH="${HOST_TP_DIR}/patches/jemalloc_hook.patch"
JEMALLOC_SRC_TARBALL="${TP_SOURCE_DIR}/${JEMALLOC_DORIS_NAME}"
JEMALLOC_SRC_TREE="${TP_SOURCE_DIR}/${JEMALLOC_DORIS_SOURCE}"
JEMALLOC_PATCHED_MARK="${JEMALLOC_SRC_TREE}/patched_mark"

# 3. Cache-hit path. We deliberately do NOT replace the container's
#    stock `installed/include/jemalloc/jemalloc.h`: the rebuilt header
#    differs by one autoconf flag (compile-time printf annotation only,
#    no ABI effect), and overwriting it would invalidate ccache for
#    every BE TU that includes jemalloc.h.
if [[ -f "${HOST_SENTINEL}" && -f "${HOST_ARCHIVE}" ]] && \
   [[ "$(cat "${HOST_SENTINEL}" 2>/dev/null)" == "${JEMALLOC_DORIS_MD5SUM}" ]]; then
    if ! cmp -s "${HOST_ARCHIVE}" "${TARGET_ARCHIVE}"; then
        install -m 0644 "${HOST_ARCHIVE}" "${TARGET_ARCHIVE}"
        echo "phase2-jemalloc: cache hit (md5=${JEMALLOC_DORIS_MD5SUM}); synced ${HOST_ARCHIVE} -> ${TARGET_ARCHIVE}."
    else
        echo "phase2-jemalloc: cache hit (md5=${JEMALLOC_DORIS_MD5SUM}); ${TARGET_ARCHIVE} already in sync."
    fi
    exit 0
fi

# 4. Cache miss. Fetch and unpack jemalloc if absent. `--no-same-owner`
#    keeps tar from chown'ing to the tarball's stored uid/gid, which
#    rootless containers cannot honor.
mkdir -p "${TP_SOURCE_DIR}"
if [[ ! -d "${JEMALLOC_SRC_TREE}" ]]; then
    if [[ ! -f "${JEMALLOC_SRC_TARBALL}" ]]; then
        echo "Fetching ${JEMALLOC_DORIS_DOWNLOAD}"
        curl -fsSL "${JEMALLOC_DORIS_DOWNLOAD}" -o "${JEMALLOC_SRC_TARBALL}"
    fi
    tar --no-same-owner -xjf "${JEMALLOC_SRC_TARBALL}" -C "${TP_SOURCE_DIR}"
fi

# 5. Apply the substantive edit of jemalloc_hook.patch (drops
#    `jemalloc_mangle.h` from the header list) via sed. Reason: `patch
#    -p0` tries to preserve POSIX ACLs and rolls back the edit when the
#    setxattr fails in a rootless container, despite reporting "Hunk
#    succeeded". Touching `patched_mark` makes download-thirdparty.sh
#    skip its own patch step. Idempotent.
JEMALLOC_HEADER_SH="${JEMALLOC_SRC_TREE}/include/jemalloc/jemalloc.sh"
if [[ ! -f "${JEMALLOC_PATCHED_MARK}" ]]; then
    sed -i \
        's|jemalloc_protos.h jemalloc_typedefs.h jemalloc_mangle.h ; do|jemalloc_protos.h jemalloc_typedefs.h ; do|' \
        "${JEMALLOC_HEADER_SH}"
    if grep -q "jemalloc_protos.h jemalloc_typedefs.h ; do" "${JEMALLOC_HEADER_SH}"; then
        touch "${JEMALLOC_PATCHED_MARK}"
    else
        echo "phase2-jemalloc: substantive edit of ${JEMALLOC_HEADER_SH} did not apply; the upstream jemalloc_hook.patch shape may have changed. Aborting." >&2
        exit 1
    fi
fi

# 6. Point libunwind detection at the prebuilt thirdparty install.
#    Reason: build-thirdparty.sh only sets CFLAGS on the configure line
#    and lets the other three flow in from env. We point at
#    `${TARGET_INSTALL}` (the container's `/var/local/thirdparty/installed/`)
#    because the bind-mounted `${HOST_TP_INSTALL}` only holds outputs of
#    this script — the prebuilt libunwind and liblzma live in the
#    container image. `LIBS=-llzma` is required because the thirdparty
#    libunwind is built with `-llzma` (build_libunwind) and autoconf's
#    AC_CHECK_LIB appends LIBS after `-lunwind`.
export CPPFLAGS="-I${TARGET_INSTALL}/include"
export LDFLAGS="-L${TARGET_INSTALL}/lib"
export LIBS="-llzma"

# 7. Invoke the patched build_jemalloc_doris. Positional args are the
#    package list (build-thirdparty.sh: `read -r -a packages <<<"${@}"`),
#    so this skips the rest of the pipeline. The patched function
#    aborts on `prof-libunwind != 1`; reaching the next line means the
#    verify passed. The install lands at ${HOST_ARCHIVE}.
echo "phase2-jemalloc: invoking build-thirdparty.sh jemalloc_doris"
bash "${HOST_TP_DIR}/build-thirdparty.sh" jemalloc_doris

# 8. Record the cache key and sync to the container's CMake-visible
#    install. Stock jemalloc.h is intentionally left in place; see
#    step 3.
echo -n "${JEMALLOC_DORIS_MD5SUM}" > "${HOST_SENTINEL}"
install -m 0644 "${HOST_ARCHIVE}" "${TARGET_ARCHIVE}"
echo "phase2-jemalloc: build complete; cached (md5=${JEMALLOC_DORIS_MD5SUM}) and synced to ${TARGET_ARCHIVE}."
