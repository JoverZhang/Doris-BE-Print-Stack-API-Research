set shell := ["bash", "-eu", "-o", "pipefail", "-c"]
set positional-arguments := true

default:
    @just --list

repos-sync:
    ./scripts/sync_repos.sh

repos-check:
    ./scripts/validate_repos.sh

# Install static .clangd into repos/source/{oceanbase,ClickHouse}.
# (Doris LSP is a side effect of `just phase2-test <variant>`, which writes
# be/ut_build_ASAN/compile_commands.json with host paths inside the submodule.)
repos-lsp:
    ./scripts/lsp/install-clangd.sh "{{justfile_directory()}}"

# Bootstrap the phase2/* branch stack in repos/source/doris-master from patches/.
phase2-bootstrap:
    @./scripts/in-container ./scripts/phase2/bootstrap.sh

# Remove every phase2/* branch from repos/source/doris-master.
phase2-teardown:
    @./scripts/in-container ./scripts/phase2/teardown.sh

# Switch to phase2/<variant> and run NativeStackActionTest in the container.
phase2-test variant:
    @./scripts/in-container ./scripts/phase2/test.sh "{{variant}}"

# Round-trip verify: tree(phase2/<variant>) == tree(re-apply patches at DORIS_BASE).
phase2-verify variant:
    @./scripts/in-container ./scripts/phase2/verify.sh "{{variant}}"

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
        docker.io/apache/doris:build-env-ldb-toolchain-latest \
        bash

# Drop into the build container and expose BE HTTP on host localhost.
phase2-shell-host host_port='8040':
    @podman run --rm -it \
        -p "127.0.0.1:{{host_port}}:8040" \
        -v "{{justfile_directory()}}:{{justfile_directory()}}" \
        -w "{{justfile_directory()}}/repos/source/doris-master" \
        -e DORIS_THIRDPARTY=/var/local/thirdparty \
        docker.io/apache/doris:build-env-ldb-toolchain-latest \
        bash
