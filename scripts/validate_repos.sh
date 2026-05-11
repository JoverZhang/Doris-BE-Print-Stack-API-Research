#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

mapfile -t path_keys < <(git config -f .gitmodules --get-regexp '^submodule\..*\.path$' | awk '{print $1}')
if [[ "${#path_keys[@]}" -eq 0 ]]; then
  echo "no source submodules declared in .gitmodules" >&2
  exit 1
fi

for path_key in "${path_keys[@]}"; do
  section="${path_key%.path}"
  path="$(git config -f .gitmodules --get "$path_key")"
  url="$(git config -f .gitmodules --get "${section}.url")"

  [[ -n "$path" && -n "$url" ]] || {
    echo "invalid .gitmodules entry: $section" >&2
    exit 1
  }

  local_line="$(git ls-files -s -- "$path")"
  [[ -n "$local_line" ]] || {
    echo "missing gitlink for source submodule: $path" >&2
    exit 1
  }

  read -r mode gitlink_commit _ <<<"$local_line"
  [[ "$mode" == "160000" ]] || {
    echo "source path is not a git submodule gitlink: $path mode=$mode" >&2
    exit 1
  }

  if [[ -d "$path/.git" || -f "$path/.git" ]]; then
    worktree_commit="$(git -C "$path" rev-parse HEAD)"
    [[ "$worktree_commit" == "$gitlink_commit" ]] || {
      echo "working tree commit mismatch for $path: gitlink=$gitlink_commit worktree=$worktree_commit" >&2
      exit 1
    }
  fi

  echo "source_repo path=$path commit=$gitlink_commit url=$url"
done

echo "source repos ok"
