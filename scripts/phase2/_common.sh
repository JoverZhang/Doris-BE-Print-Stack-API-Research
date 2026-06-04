# Reason: every phase2 script needs the same paths and variant list. Defining
# them once keeps drift between scripts impossible.
# Local: sourced helper, never invoked directly.

# Reason: the upstream Doris commit that patches/ apply on top of. Every
# phase2/* branch descends from this; changing it requires re-baselining
# every variant. Env-overridable for one-off bootstrap from a different base.
# Local: harness config.
DORIS_BASE="${DORIS_BASE:-fc639a14a6cb19e23565c868e62d4c170337d5d8}"

# Reason: variants known to the harness; common is implicit.
# snapshot-remote-unwind is temporarily disabled because its patches still
# target `native_stack_collect.cpp`, which does not exist on `phase2/common`
# after the print_stack refactor. Re-add it after its variant patches are
# rewritten against the new `capture_into_slot` seam.
# Local: harness config.
VARIANTS="fp-walk ck-phdr-unwind ob-kill60"

# Resolve the project root: prefer the PROJECT_ROOT exported by in-container;
# fall back to git when sourced from the host.
if [[ -z "${PROJECT_ROOT:-}" ]]; then
    PROJECT_ROOT="$(git rev-parse --show-toplevel)"
fi

DORIS_REPO="${PROJECT_ROOT}/repos/source/doris-master"

# Reason: every git op inside this submodule's worktree needs a committer
# identity for git am. The values are local-only; produced commits never
# leave this checkout (format-patch emits new files from them).
# Local: harness helper.
ensure_git_identity() {
    local repo="$1"
    git -C "$repo" config user.name >/dev/null 2>&1 || \
        git -C "$repo" config user.name mira
    git -C "$repo" config user.email >/dev/null 2>&1 || \
        git -C "$repo" config user.email mira@example.invalid
}

# Reason: shared dirty-worktree guard. The naive `diff-index --quiet HEAD --`
# false-positives after a submodule init (stat cache stale) and on submodule
# pointer movement. Refresh the stat cache first; ignore submodule diffs
# (they are normal after init/build and the user is not editing them).
# Local: harness helper.
assert_clean_worktree() {
    local wt="$1"
    git -C "$wt" update-index --refresh -q >/dev/null 2>&1 || true
    if ! git -C "$wt" diff-index --quiet --ignore-submodules HEAD --; then
        echo "error: $wt is dirty" >&2
        exit 1
    fi
}

# Reason: a stale verify worktree (left from a crashed run) blocks the next
# verify. Removing the dir and pruning the registry recovers cleanly.
# Local: harness helper.
cleanup_worktree() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        rm -rf "$dir"
    fi
    git -C "$DORIS_REPO" worktree prune
}
