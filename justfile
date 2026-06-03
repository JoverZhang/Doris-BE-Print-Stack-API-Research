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
# Uses Doris's default ASAN UT build (be/ut_build_ASAN). Sibling recipes
# below run the same suite under RELEASE and TSAN.
phase2-test variant:
    @./scripts/in-container ./scripts/phase2/test.sh "{{variant}}"

# Same as phase2-test but with cmake RELEASE flags (-O3 -DNDEBUG, no ASan).
# Build lands at be/ut_build_RELEASE; production codegen check for fp-walk.
phase2-test-release variant:
    @BUILD_TYPE_UT=RELEASE ./scripts/in-container ./scripts/phase2/test.sh "{{variant}}"

# Same as phase2-test but with ThreadSanitizer (-O1 -fsanitize=thread).
# Build lands at be/ut_build_TSAN; best-effort, signal-handler/atomic
# instrumentation may flag or block (see docs/phase2-test-plan.md).
phase2-test-tsan variant:
    @BUILD_TYPE_UT=TSAN ./scripts/in-container ./scripts/phase2/test.sh "{{variant}}"

# Diagnostic: switch to phase2/<variant> or phase2/base and run one gtest
# filter without deleting that build dir. Useful for base-vs-variant checks.
phase2-test-filter variant filter:
    @./scripts/in-container ./scripts/phase2/test-filter.sh "{{variant}}" "{{filter}}"

phase2-test-filter-release variant filter:
    @BUILD_TYPE_UT=RELEASE ./scripts/in-container ./scripts/phase2/test-filter.sh "{{variant}}" "{{filter}}"

phase2-test-filter-tsan variant filter:
    @BUILD_TYPE_UT=TSAN ./scripts/in-container ./scripts/phase2/test-filter.sh "{{variant}}" "{{filter}}"

# fp-walk only: Release flags plus USE_JEMALLOC=ON, matching the production
# allocator shape more closely than run-be-ut.sh (which hard-codes jemalloc OFF).
# Build lands at be/ut_build_JEMALLOC_RELEASE.
phase2-test-jemalloc variant:
    @./scripts/in-container ./scripts/phase2/test-jemalloc.sh "{{variant}}"

# Run the suite under all three build types (ASAN, RELEASE, TSAN) in
# sequence plus the fp-walk jemalloc smoke where applicable. Each mode uses its
# own sibling build dir, so this only re-runs cmake/ninja per mode, not others.
phase2-test-all variant:
    @just phase2-test "{{variant}}"
    @just phase2-test-release "{{variant}}"
    @if [ "{{variant}}" = "fp-walk" ]; then just phase2-test-jemalloc "{{variant}}"; fi
    @just phase2-test-tsan "{{variant}}"

# Run every BE UT under the selected branch without deleting the build dir.
# Override build type with BUILD_TYPE_UT=RELEASE/TSAN and build parallelism
# with PHASE2_UT_JOBS=<n>. Defaults use Doris's own job heuristic.
phase2-full-ut variant:
    @./scripts/in-container ./scripts/phase2/full-ut.sh "{{variant}}"

# CI-parity full BE UT: delete the selected be/ut_build_${BUILD_TYPE_UT} first.
phase2-full-ut-clean variant:
    @./scripts/in-container ./scripts/phase2/full-ut.sh "{{variant}}" --clean

phase2-full-ut-base:
    @just phase2-full-ut base

phase2-full-ut-base-clean:
    @just phase2-full-ut-clean base

phase2-full-ut-release variant:
    @BUILD_TYPE_UT=RELEASE ./scripts/in-container ./scripts/phase2/full-ut.sh "{{variant}}"

phase2-full-ut-tsan variant:
    @BUILD_TYPE_UT=TSAN ./scripts/in-container ./scripts/phase2/full-ut.sh "{{variant}}"

phase2-full-ut-base-release:
    @just phase2-full-ut-release base

phase2-full-ut-base-tsan:
    @just phase2-full-ut-tsan base

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
