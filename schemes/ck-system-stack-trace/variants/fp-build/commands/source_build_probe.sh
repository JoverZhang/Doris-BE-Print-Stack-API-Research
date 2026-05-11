#!/usr/bin/env bash
set -euo pipefail

# Audit script for the source-build preflight recorded for task #28.
# It intentionally documents requirements instead of running the long build.

echo "Source-build command:"
echo "CK_VARIANT=fp-build just ck-system-stack-trace"
echo
echo "Requirements observed in task #28:"
echo "- ClickHouse source tree at tag v26.3.10.62-lts, commit e1c11930c28196f954a93287e43c1aa112c8c607."
echo "- All 129 git submodules initialized."
echo "- rustup toolchain nightly-2025-07-07 installed; CMake fails before build without it."
echo "- If <scheme>/build/fp/programs/clickhouse already exists, the fp-build variant reuses it; otherwise it builds from <repo>/repos/source/ClickHouse-v26.3.10.62-lts."
echo
echo "Previous task #23 blockers resolved in task #28:"
echo "- Recursive submodule checkout was completed outside this scheme directory."
echo "- Missing Rust nightly was fixed with: rustup toolchain install nightly-2025-07-07."
