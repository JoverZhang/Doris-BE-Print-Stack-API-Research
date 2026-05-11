#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

check_submodule() {
  local name="$1"
  local path="$2"
  local url="$3"
  local commit="$4"

  local module_url
  module_url="$(git config -f .gitmodules --get "submodule.${path}.url" || true)"
  [[ "$module_url" == "$url" ]] || {
    echo "submodule url mismatch for $name: expected $url, got ${module_url:-<missing>}" >&2
    exit 1
  }

  local index_line
  index_line="$(git ls-files -s -- "$path")"
  [[ -n "$index_line" ]] || {
    echo "missing gitlink for $name at $path" >&2
    exit 1
  }

  local mode object
  read -r mode object _ <<<"$index_line"
  [[ "$mode" == "160000" ]] || {
    echo "source path is not a git submodule gitlink: $path mode=$mode" >&2
    exit 1
  }
  [[ "$object" == "$commit" ]] || {
    echo "gitlink commit mismatch for $name: expected $commit, got $object" >&2
    exit 1
  }

  grep -q "commit: $commit" repos.lock || {
    echo "repos.lock missing commit for $name: $commit" >&2
    exit 1
  }
  grep -q "path: $path" repos.lock || {
    echo "repos.lock missing path for $name: $path" >&2
    exit 1
  }
  grep -q "url: $url" repos.lock || {
    echo "repos.lock missing url for $name: $url" >&2
    exit 1
  }

  if [[ -d "$path/.git" || -f "$path/.git" ]]; then
    local worktree_commit
    worktree_commit="$(git -C "$path" rev-parse HEAD)"
    [[ "$worktree_commit" == "$commit" ]] || {
      echo "working tree commit mismatch for $name: expected $commit, got $worktree_commit" >&2
      exit 1
    }
  fi
}

check_submodule \
  clickhouse \
  repos/source/ClickHouse-v26.3.10.62-lts \
  https://github.com/ClickHouse/ClickHouse.git \
  e1c11930c28196f954a93287e43c1aa112c8c607

check_submodule \
  oceanbase \
  repos/source/oceanbase-v4.5.0_CE \
  https://github.com/oceanbase/oceanbase.git \
  0e8d5ad012baf0953b2032a35a88bdf8886e9a7a

check_submodule \
  obstack \
  repos/source/obstack-master \
  https://github.com/oceanbase/obstack.git \
  d91edd6d882a33b69164f8d3e809092408da3a33

echo "source repos ok"
