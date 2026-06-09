#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=common.sh
source "$ROOT/scripts/common.sh"

need_tool "$CC_BIN"
need_tool "$CXX_BIN"
need_tool autoreconf
need_tool make
need_tool tar
require_linux_x86_64
[[ -f "$LIBUNWIND_SRC/configure.ac" ]] || fail "missing libunwind source: $LIBUNWIND_SRC"

mkdir -p "$OUT"
rm -rf "$LIBUNWIND_COPY" "$LIBUNWIND_BUILD" "$LIBUNWIND_INSTALL"
mkdir -p "$LIBUNWIND_COPY" "$LIBUNWIND_BUILD" "$LIBUNWIND_INSTALL/include" "$LIBUNWIND_INSTALL/lib"

echo "libunwind source: $LIBUNWIND_SRC"
echo "libunwind version: $(libunwind_version)"

(
    cd "$LIBUNWIND_SRC"
    tar --exclude=.git -cf - .
) | (
    cd "$LIBUNWIND_COPY"
    tar -xf -
)

autoreconf_log="$OUT/autoreconf.log"
echo "running autoreconf (log: $autoreconf_log)"
(
    cd "$LIBUNWIND_COPY"
    autoreconf -i
) > "$autoreconf_log" 2>&1 || {
    tail -n 80 "$autoreconf_log" >&2
    fail "autoreconf failed"
}

libunwind_cflags=(
    "-I$LIBUNWIND_INSTALL/include"
    "-std=c99"
    "-D_LIBUNWIND_NO_HEAP=1"
    "-D_DEBUG"
    "-D_LIBUNWIND_IS_NATIVE_ONLY"
    "-O3"
    "-fno-exceptions"
    "-funwind-tables"
    "-fno-sanitize=all"
    "-nostdinc++"
    "-fno-rtti"
    "-Wno-error=incompatible-pointer-types"
)

build_log="$OUT/libunwind-build.log"
echo "building libunwind (log: $build_log)"
(
    cd "$LIBUNWIND_BUILD"
    CC="$CC_BIN" \
    CXX="$CXX_BIN" \
    CFLAGS="${libunwind_cflags[*]}" \
    LDFLAGS="-llzma" \
    "$LIBUNWIND_COPY/configure" \
        --prefix="$LIBUNWIND_INSTALL" \
        --disable-shared \
        --enable-static \
        --disable-tests \
        --disable-documentation
    make -j"$JOBS"
    make install
) > "$build_log" 2>&1 || {
    tail -n 120 "$build_log" >&2
    fail "libunwind build failed"
}
