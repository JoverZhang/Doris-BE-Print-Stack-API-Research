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

validate:
    just repos-check
    just phase1 validate

phase1 *args:
    @just --justfile archive/phase1/justfile "$@"
