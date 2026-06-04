#!/usr/bin/env bash
# Reason: convert patches/ into the branch stack on first setup. Without it,
# the harness has no branches to operate on. Common is strict (the variant
# stack is meaningless without it); each variant is tolerated independently
# so one stale patch series does not block the rest.
# Local: one-shot harness setup, called by `just phase2-bootstrap [base|common]`.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

final_target="${1:-common}"
case "$final_target" in
    base | common) ;;
    *)
        echo "usage: bootstrap.sh [base|common]" >&2
        exit 2
        ;;
esac

# 1. Refuse if any phase2/* branch already exists.
if git -C "$DORIS_REPO" show-ref --verify --quiet refs/heads/phase2/base; then
    echo "error: phase2/* branches already exist in $DORIS_REPO" >&2
    exit 1
fi

# 2. Make sure the submodule has a committer identity for git am.
ensure_git_identity "$DORIS_REPO"

# 3. Create phase2/base at DORIS_BASE and switch to it.
git -C "$DORIS_REPO" switch -c phase2/base "$DORIS_BASE"

# 4. Initialize submodules so the build has contrib/faiss, contrib/openblas,
#    and others. Recursive so nested submodules (e.g. apache-orc) check out too.
echo "initializing submodules (may take a few minutes on cold cache)..."
git -C "$DORIS_REPO" submodule update --init --recursive

# 5. Create phase2/common; apply patches/common/*.patch strictly.
git -C "$DORIS_REPO" switch -c phase2/common
git -C "$DORIS_REPO" am "$PROJECT_ROOT/patches/common/"*.patch

# 6. For each variant: branch from phase2/common; try to apply. On failure
#    abort cleanly so the next variant can still run. ck-phdr-unwind and
#    ob-kill60 both need `libjemalloc_doris.a` rebuilt with
#    `--enable-prof-libunwind`; their variant patches add the flag and a
#    verify to Doris's `thirdparty/build-thirdparty.sh`, and the harness
#    wrapper below ensures the jemalloc source is unpacked + invokes the
#    patched build. The rebuild writes to
#    `${DORIS_THIRDPARTY}/installed/lib/libjemalloc_doris.a` (the
#    container's standard install root), which is where CMake's
#    `add_thirdparty(jemalloc ...)` already looks — no in-tree path swap.
#    The wrapper is idempotent (probes config.log for `prof-libunwind:1`)
#    and md5-keyed, so the second variant in this loop is a cache hit.
clean=()
broken=()
for v in $VARIANTS; do
    git -C "$DORIS_REPO" switch phase2/common
    git -C "$DORIS_REPO" switch -c "phase2/$v"
    if git -C "$DORIS_REPO" am "$PROJECT_ROOT/patches/$v/"*.patch; then
        clean+=("$v")
        if [[ "$v" == "ck-phdr-unwind" || "$v" == "ob-kill60" ]]; then
            DORIS_REPO="$DORIS_REPO" "$PROJECT_ROOT/scripts/phase2/build-jemalloc-prof-libunwind.sh"
        fi
    else
        git -C "$DORIS_REPO" am --abort 2>/dev/null || true
        git -C "$DORIS_REPO" switch phase2/common
        git -C "$DORIS_REPO" branch -D "phase2/$v"
        broken+=("$v")
    fi
done

# 7. Leave on the requested branch/default. `base` means detached at DORIS_BASE
# rather than a mutable branch name such as master.
if [[ "$final_target" == "base" ]]; then
    git -C "$DORIS_REPO" switch --detach "$DORIS_BASE"
else
    git -C "$DORIS_REPO" switch phase2/common
fi

echo
echo "bootstrap summary:"
echo "  final:   ${final_target}"
echo "  clean:   common ${clean[*]}"
if [[ ${#broken[@]} -gt 0 ]]; then
    echo "  broken:  ${broken[*]}"
    echo
    echo "broken variants need patch regeneration. Investigate with:"
    echo "  cd $DORIS_REPO && git am --3way \"$PROJECT_ROOT/patches/<v>/\"*.patch"
else
    echo "  broken:  none"
fi
