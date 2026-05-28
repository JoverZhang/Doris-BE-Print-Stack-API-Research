set shell := ["bash", "-eu", "-o", "pipefail", "-c"]
set positional-arguments := true

default:
    @just --list

repos-sync:
    ./scripts/sync_repos.sh

repos-check:
    ./scripts/validate_repos.sh

validate:
    just repos-check
    just phase1 validate

phase1 *args:
    @just --justfile archive/phase1/justfile "$@"
