#!/usr/bin/env bash
set -euo pipefail

BASE_COMMIT="c24d454f15cee2d937ef4749270a3ecb449eafe6"
COMMON_TARGET="common-api"
COMMON_PATCH_KEY="common"
AM_USER_NAME="mira"
AM_USER_EMAIL="mira@example.invalid"

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# PHASE2_ROOT lets a task worktree reuse the persistent phase2/ worktrees of the
# main project repo instead of materializing a fresh phase2/ under itself. The
# doris-master submodule is 14 GB, so cloning it per task is impractical.
PHASE2_ROOT="${PHASE2_ROOT:-$ROOT/phase2}"

# DORIS_SOURCE_REPO lets a task worktree point source_repo() at the main
# project's initialized submodule when its own repos/source/doris-master is an
# uninitialized stub.
DORIS_SOURCE_REPO="${DORIS_SOURCE_REPO:-$ROOT/repos/source/doris-master}"

usage() {
  cat <<'EOF'
usage:
  scripts/phase2_patches.sh apply <target>
  scripts/phase2_patches.sh clean-apply <target>
  scripts/phase2_patches.sh diff <target> [--output FILE]
  scripts/phase2_patches.sh export <target>
  scripts/phase2_patches.sh status [target]

targets:
  common, common-api, or a directory under patches/ such as fp-walk

notes:
  clean-apply deletes untracked and ignored files under phase2/<target>.
  Use it only when the user explicitly asks for a clean re-apply.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

normalize_target() {
  local target="${1:-}"
  case "$target" in
    common|common-api) echo "$COMMON_TARGET" ;;
    "") die "missing target" ;;
    *) echo "$target" ;;
  esac
}

patch_key_for() {
  local target="$1"
  if [[ "$target" == "$COMMON_TARGET" ]]; then
    echo "$COMMON_PATCH_KEY"
  else
    echo "$target"
  fi
}

worktree_for() {
  local target="$1"
  echo "$PHASE2_ROOT/$target"
}

patch_dir_for() {
  local target="$1"
  local key
  key="$(patch_key_for "$target")"
  echo "$ROOT/patches/$key"
}

source_repo() {
  echo "$DORIS_SOURCE_REPO"
}

list_targets() {
  {
    echo "$COMMON_TARGET"
    find "$ROOT/patches" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
      | sed "s/^$COMMON_PATCH_KEY$/$COMMON_TARGET/"
  } | sort -u
}

ensure_known_target() {
  local target="$1"
  local patch_dir
  patch_dir="$(patch_dir_for "$target")"
  [[ -d "$patch_dir" ]] || die "unknown target '$target': missing $patch_dir"
}

collect_patches() {
  local target="$1"
  local patch_dir
  patch_dir="$(patch_dir_for "$target")"
  [[ -d "$patch_dir" ]] || die "missing patch directory: $patch_dir"

  mapfile -t PATCH_FILES < <(find "$patch_dir" -maxdepth 1 -type f -name '*.patch' | sort)
  [[ "${#PATCH_FILES[@]}" -gt 0 ]] || die "no .patch files in $patch_dir"
}

ensure_worktree() {
  local target="$1"
  local wt
  wt="$(worktree_for "$target")"

  if [[ -d "$wt" ]]; then
    git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
      || die "$wt exists but is not a git worktree"
    return
  fi

  local src
  src="$(source_repo)"
  [[ -d "$src" ]] || die "cannot create $wt: missing source repo $src"
  mkdir -p "$PHASE2_ROOT"
  git -C "$src" worktree add --detach "$wt" "$BASE_COMMIT"
}

require_clean_tracked() {
  local wt="$1"
  local dirty
  dirty="$(git -C "$wt" status --porcelain --untracked-files=no --ignore-submodules=all)"
  if [[ -n "$dirty" ]]; then
    echo "$dirty" >&2
    die "$wt has tracked changes; commit/export/stash them before continuing"
  fi
}

require_no_git_operation_in_progress() {
  local wt="$1"
  local rebase_apply rebase_merge merge_head
  rebase_apply="$(git -C "$wt" rev-parse --git-path rebase-apply)"
  rebase_merge="$(git -C "$wt" rev-parse --git-path rebase-merge)"
  merge_head="$(git -C "$wt" rev-parse --git-path MERGE_HEAD)"
  [[ ! -e "$rebase_apply" && ! -e "$rebase_merge" && ! -e "$merge_head" ]] \
    || die "$wt has an in-progress git operation; resolve it or run git -C $wt am --abort"
}

git_am_patches() {
  local wt="$1"
  shift
  git -C "$wt" \
    -c "user.name=$AM_USER_NAME" \
    -c "user.email=$AM_USER_EMAIL" \
    am --3way --keep-non-patch --committer-date-is-author-date "$@"
}

apply_patch_series() {
  local target="$1"
  local wt="$2"

  collect_patches "$COMMON_TARGET"
  git_am_patches "$wt" "${PATCH_FILES[@]}"

  if [[ "$target" != "$COMMON_TARGET" ]]; then
    collect_patches "$target"
    git_am_patches "$wt" "${PATCH_FILES[@]}"
  fi
}

common_patch_count() {
  collect_patches "$COMMON_TARGET"
  echo "${#PATCH_FILES[@]}"
}

commit_after_common() {
  local wt="$1"
  local count
  count="$(common_patch_count)"

  mapfile -t COMMITS_AFTER_BASE < <(git -C "$wt" rev-list --reverse "$BASE_COMMIT..HEAD")
  if (( "${#COMMITS_AFTER_BASE[@]}" < count )); then
    die "$wt does not contain $count common patch commit(s) after $BASE_COMMIT"
  fi

  echo "${COMMITS_AFTER_BASE[$((count - 1))]}"
}

diff_base_for() {
  local target="$1"
  local wt="$2"
  if [[ "$target" == "$COMMON_TARGET" ]]; then
    echo "$BASE_COMMIT"
  else
    commit_after_common "$wt"
  fi
}

cmd_apply() {
  local target
  target="$(normalize_target "${1:-}")"
  ensure_known_target "$target"
  ensure_worktree "$target"

  local wt
  wt="$(worktree_for "$target")"
  require_clean_tracked "$wt"
  require_no_git_operation_in_progress "$wt"

  git -C "$wt" reset --hard "$BASE_COMMIT" >/dev/null

  apply_patch_series "$target" "$wt"

  echo "applied target=$target worktree=$wt head=$(git -C "$wt" rev-parse --short HEAD)"
}

cmd_clean_apply() {
  local target
  target="$(normalize_target "${1:-}")"
  ensure_known_target "$target"
  ensure_worktree "$target"

  local wt
  wt="$(worktree_for "$target")"
  require_no_git_operation_in_progress "$wt"

  echo "cleaning target=$target worktree=$wt"
  git -C "$wt" reset --hard "$BASE_COMMIT" >/dev/null
  git -C "$wt" clean -ffdx

  apply_patch_series "$target" "$wt"

  echo "applied target=$target worktree=$wt head=$(git -C "$wt" rev-parse --short HEAD)"
}

cmd_diff() {
  local target_arg="${1:-}"
  [[ -n "$target_arg" ]] || die "missing target"
  shift || true

  local output=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --output)
        [[ "$#" -ge 2 ]] || die "--output requires a file"
        output="$2"
        shift 2
        ;;
      *) die "unknown diff argument: $1" ;;
    esac
  done

  local target wt base
  target="$(normalize_target "$target_arg")"
  ensure_known_target "$target"
  ensure_worktree "$target"
  wt="$(worktree_for "$target")"
  base="$(diff_base_for "$target" "$wt")"

  if [[ -n "$output" ]]; then
    mkdir -p "$(dirname "$output")"
    git -C "$wt" diff --binary --ignore-submodules=all "$base" -- . >"$output"
  else
    git -C "$wt" diff --binary --ignore-submodules=all "$base" -- .
  fi
}

cmd_export() {
  local target
  target="$(normalize_target "${1:-}")"
  ensure_known_target "$target"
  ensure_worktree "$target"

  local wt patch_dir base commit_count tmp
  wt="$(worktree_for "$target")"
  patch_dir="$(patch_dir_for "$target")"
  require_clean_tracked "$wt"
  require_no_git_operation_in_progress "$wt"

  base="$(diff_base_for "$target" "$wt")"
  commit_count="$(git -C "$wt" rev-list --count "$base..HEAD")"
  [[ "$commit_count" -gt 0 ]] || die "no commits to export for $target from $base..HEAD"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/phase2-patches.XXXXXX")"
  if ! git -C "$wt" format-patch --output-directory "$tmp" "$base..HEAD" >/dev/null; then
    rm -rf "$tmp"
    return 1
  fi

  mkdir -p "$patch_dir"
  rm -f "$patch_dir"/*.patch
  cp "$tmp"/*.patch "$patch_dir"/
  rm -rf "$tmp"
  echo "exported target=$target commits=$commit_count patch_dir=$patch_dir"
}

target_status() {
  local target="$1"
  local wt patch_dir head dirty_count patch_count cache_state
  wt="$(worktree_for "$target")"
  patch_dir="$(patch_dir_for "$target")"
  patch_count=0
  if [[ -d "$patch_dir" ]]; then
    patch_count="$(find "$patch_dir" -maxdepth 1 -type f -name '*.patch' | wc -l)"
  fi

  if [[ -d "$wt" ]] && git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    head="$(git -C "$wt" rev-parse --short HEAD)"
    dirty_count="$(git -C "$wt" status --porcelain --untracked-files=no --ignore-submodules=all | wc -l)"
    if [[ -d "$wt/be/build_Release" || -d "$wt/output" || -d "$wt/be/output" ]]; then
      cache_state="present"
    else
      cache_state="absent"
    fi
  else
    head="missing"
    dirty_count="-"
    cache_state="-"
  fi

  printf 'target=%s worktree=%s head=%s patches=%s tracked_dirty=%s build_cache=%s\n' \
    "$target" "$wt" "$head" "$patch_count" "$dirty_count" "$cache_state"
}

cmd_status() {
  if [[ "$#" -gt 0 ]]; then
    local target
    target="$(normalize_target "$1")"
    ensure_known_target "$target"
    target_status "$target"
    return
  fi

  local target
  while read -r target; do
    ensure_known_target "$target"
    target_status "$target"
  done < <(list_targets)
}

main() {
  local cmd="${1:-}"
  if [[ -z "$cmd" || "$cmd" == "-h" || "$cmd" == "--help" ]]; then
    usage
    exit 0
  fi
  shift

  case "$cmd" in
    apply) cmd_apply "$@" ;;
    clean-apply) cmd_clean_apply "$@" ;;
    diff) cmd_diff "$@" ;;
    export) cmd_export "$@" ;;
    status) cmd_status "$@" ;;
    *) usage >&2; die "unknown command: $cmd" ;;
  esac
}

main "$@"
