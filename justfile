set shell := ["bash", "-eu", "-o", "pipefail", "-c"]
set positional-arguments := true

default:
    @just --list

repos-sync:
    ./scripts/sync_repos.sh

repos-check:
    ./scripts/validate_repos.sh

phase2-apply target:
    @./scripts/phase2_patches.sh apply "{{target}}"

phase2-clean-apply target:
    @./scripts/phase2_patches.sh clean-apply "{{target}}"

phase2-diff target:
    @./scripts/phase2_patches.sh diff "{{target}}"

phase2-export target:
    @./scripts/phase2_patches.sh export "{{target}}"

phase2-status target="":
    @if [[ -n "{{target}}" ]]; then \
        ./scripts/phase2_patches.sh status "{{target}}"; \
    else \
        ./scripts/phase2_patches.sh status; \
    fi

# Apply <variant> patches (common first, then the variant) and build+run the
# native-stack unit tests in the build-env image. <variant> is a worktree name:
# common-api or fp-walk.
#
# The project root is mapped into the container at its host path so the worktree's
# .git pointer resolves; DORIS_THIRDPARTY points at the image's prebuilt
# thirdparty so the build never recompiles it; and scripts/podman-git-shim is
# prepended to PATH so run-be-ut.sh's `git submodule update` is a no-op (the
# submodules are already checked out -- see that script for why).
phase2-test variant:
    ./scripts/phase2_patches.sh apply "{{variant}}"
    podman run --rm \
        -e DORIS_THIRDPARTY=/var/local/thirdparty \
        -v "{{justfile_directory()}}:{{justfile_directory()}}" \
        -w "{{justfile_directory()}}/phase2/{{ if variant == "common" { "common-api" } else { variant } }}" \
        docker.io/apache/doris:build-env-ldb-toolchain-latest \
        bash -lc 'export PATH="{{justfile_directory()}}/scripts/podman-git-shim:$PATH"; ./run-be-ut.sh --run --filter="NativeStackActionTest.*" -j "$(nproc)"'

validate:
    just repos-check
    just phase1 validate

phase1 *args:
    @just --justfile archive/phase1/justfile "$@"
