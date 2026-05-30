set shell := ["bash", "-eu", "-o", "pipefail", "-c"]
set positional-arguments := true

default:
    @just --list

repos-sync:
    ./scripts/sync_repos.sh

repos-check:
    ./scripts/validate_repos.sh

# Bootstrap the .worktree/phase2 stack from patches/.
phase2-bootstrap:
    @./scripts/in-container ./scripts/phase2/bootstrap.sh

# Remove the worktree and every phase2/* branch.
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

# Drop into bash inside the build container, cwd at the worktree.
phase2-shell:
    @podman run --rm -it \
        -v "{{justfile_directory()}}:{{justfile_directory()}}" \
        -w "{{justfile_directory()}}/.worktree/phase2" \
        -e DORIS_THIRDPARTY=/var/local/thirdparty \
        docker.io/apache/doris:build-env-ldb-toolchain-latest \
        bash

validate:
    just repos-check
    just phase1 validate

phase1 *args:
    @just --justfile archive/phase1/justfile "$@"
