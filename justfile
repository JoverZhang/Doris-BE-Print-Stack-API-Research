set shell := ["bash", "-eu", "-o", "pipefail", "-c"]
set positional-arguments := true

default:
    @just --list

repos-sync:
    ./scripts/sync_repos.sh

repos-check:
    ./scripts/validate_repos.sh

# Install static .clangd into repos/source/{oceanbase,ClickHouse}.
# (Doris LSP is a side effect of `just phase2-test new-ut <target> asan <filter>`,
# which writes be/ut_build_ASAN/compile_commands.json inside the submodule.)
repos-lsp:
    ./scripts/lsp/install-clangd.sh "{{justfile_directory()}}"

# Bootstrap the phase2/* branch stack. final_target is common or base.
phase2-bootstrap final_target='common':
    @./scripts/in-container ./scripts/phase2/bootstrap.sh "{{final_target}}"

# Reset Doris source artifacts and remove every phase2/* branch; preserves build dirs and ccache.
phase2-reset:
    @./scripts/in-container ./scripts/phase2/reset.sh

# Switch to phase2/<target> and run BE UT through one explicit test entrypoint.
# Usage: just phase2-test <new-ut|full-ut> <base|common|variant> <asan|release|tsan|jemalloc> <gtest-filter>
# Set DORIS_BE_JOBS=<n> for build parallelism and DORIS_BE_CLEAN=1 for CI-parity clean rebuilds.
phase2-test suite target mode filter:
    @./scripts/in-container ./scripts/phase2/test.sh "{{suite}}" "{{target}}" "{{mode}}" "{{filter}}"

# Round-trip verify: tree(phase2/<variant>) == tree(re-apply patches at DORIS_BASE).
phase2-verify variant:
    @./scripts/in-container ./scripts/phase2/verify.sh "{{variant}}"

# Cheap shell self-test for ck-phdr-unwind preflight failure modes.
phase2-ck-preflight-selftest:
    @./scripts/in-container ./scripts/phase2/check-ck-phdr-unwind-selftest.sh

# Regenerate patches/ from the branches. With no arg, exports common and all variants.
phase2-export variant='':
    @./scripts/in-container ./scripts/phase2/export.sh "{{variant}}"

# Rebase every variant on phase2/common; abort the loop on conflict.
phase2-rebase-all:
    @./scripts/in-container ./scripts/phase2/rebase-all.sh

# Show current branch and per-scope commit/patch counts.
phase2-status:
    @./scripts/in-container ./scripts/phase2/status.sh

# Drop into bash inside the build container, cwd at the doris-master submodule.
phase2-shell:
    @podman run --rm -it \
        -v "{{justfile_directory()}}:{{justfile_directory()}}" \
        -w "{{justfile_directory()}}/repos/source/doris-master" \
        -e DORIS_THIRDPARTY=/var/local/thirdparty \
        -e CCACHE_DIR="{{justfile_directory()}}/.tmp/ccache" \
        -e CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-50G}" \
        -e CCACHE_BASEDIR="{{justfile_directory()}}" \
        -e CCACHE_NOHASHDIR=true \
        docker.io/apache/doris:build-env-ldb-toolchain-latest \
        bash

# Drop into the build container and expose BE HTTP on host localhost.
phase2-shell-host host_port='8040':
    @podman run --rm -it \
        -p "127.0.0.1:{{host_port}}:8040" \
        -v "{{justfile_directory()}}:{{justfile_directory()}}" \
        -w "{{justfile_directory()}}/repos/source/doris-master" \
        -e DORIS_THIRDPARTY=/var/local/thirdparty \
        -e CCACHE_DIR="{{justfile_directory()}}/.tmp/ccache" \
        -e CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-50G}" \
        -e CCACHE_BASEDIR="{{justfile_directory()}}" \
        -e CCACHE_NOHASHDIR=true \
        docker.io/apache/doris:build-env-ldb-toolchain-latest \
        bash
