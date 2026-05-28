#!/usr/bin/env bash
set -euo pipefail

# Build image used for all commands:
# docker.io/apache/doris:build-env-ldb-toolchain-latest

# Worktree creation from the common API commit.
git -C repos/source/doris-master worktree add \
  /home/mira/lab/projects/Doris-BE-Print-Stack-API-Research/phase2/ob-kill60 \
  -b phase2-ob-kill60 \
  055bb465015fa6bcd61f9e33f352de78475fcc2e

# Full build. This linked and installed be/output/lib/doris_be.
# The final root output copy printed cp -p permission preservation warnings
# on this bind mount; C++ build/link succeeded.
docker run --rm \
  -v "$PWD:/workspace/project" \
  -v "$PWD:/home/mira/lab/projects/Doris-BE-Print-Stack-API-Research" \
  -w /workspace/project/phase2/ob-kill60 \
  docker.io/apache/doris:build-env-ldb-toolchain-latest \
  bash -lc 'set -o pipefail; DISABLE_BE_JAVA_EXTENSIONS=ON DISABLE_BE_CDC_CLIENT=ON ./build.sh --be -j 8'

# Successful target verification after the build.
docker run --rm \
  -v "$PWD:/workspace/project" \
  -v "$PWD:/home/mira/lab/projects/Doris-BE-Print-Stack-API-Research" \
  -w /workspace/project/phase2/ob-kill60 \
  docker.io/apache/doris:build-env-ldb-toolchain-latest \
  bash -lc 'set -o pipefail; cmake --build be/build_Release --target doris_be -j 8'

# Runtime setup used for local standalone BE smoke.
mkdir -p phase2/ob-kill60/be/output/www phase2/ob-kill60/be/output/storage phase2/ob-kill60/be/output/log
cp -a phase2/ob-kill60/webroot/be/. phase2/ob-kill60/be/output/www/
# Runtime-only conf line appended to phase2/ob-kill60/be/output/conf/be.conf:
# enable_java_support = false

docker run -d --name doris-ob-kill60-test -p 18042:8040 \
  -v "$PWD:/workspace/project" \
  -v "$PWD:/home/mira/lab/projects/Doris-BE-Print-Stack-API-Research" \
  -w /workspace/project/phase2/ob-kill60 \
  docker.io/apache/doris:build-env-ldb-toolchain-latest \
  bash -lc 'export JAVA_HOME=/usr/lib/jvm/jdk-17.0.2; export SKIP_CHECK_ULIMIT=true; unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY; be/output/bin/start_be.sh --console'

# Representative API commands.
curl -fsS 'http://127.0.0.1:18042/api/debug/native_stack?timeout_ms=5000&max_frames=16' \
  -o evidence/phase2/variants/ob-kill60/api/all-threads.json
curl -fsS 'http://127.0.0.1:18042/api/debug/native_stack?tid=746&timeout_ms=1000&max_frames=16' \
  -o evidence/phase2/variants/ob-kill60/api/one-tid.json
curl -fsS 'http://127.0.0.1:18042/api/debug/native_stack?tid=999999999&timeout_ms=1000&max_frames=16' \
  -o evidence/phase2/variants/ob-kill60/api/missing-tid.json
curl -fsS 'http://127.0.0.1:18042/api/debug/native_stack?timeout_ms=10&test_sleep_ms=50&max_frames=16' \
  -o evidence/phase2/variants/ob-kill60/api/timeout.json

# Busy check: hold one request with test_sleep_ms, then issue another request.
(
  curl -fsS --max-time 15 \
    'http://127.0.0.1:18042/api/debug/native_stack?timeout_ms=5000&test_sleep_ms=1000&max_frames=4' \
    -o evidence/phase2/variants/ob-kill60/api/busy-holder.json
) &
sleep 0.1
curl -fsS 'http://127.0.0.1:18042/api/debug/native_stack?timeout_ms=1000&max_frames=4' \
  -o evidence/phase2/variants/ob-kill60/api/busy.json
wait

# Offline symbolization of API-returned doris_be DSO offsets.
jq -r '[.threads[].frames[]? | select(.dso|endswith("/doris_be")) | .dso_offset] | unique | .[:20][]' \
  evidence/phase2/variants/ob-kill60/api/all-threads.json \
  > evidence/phase2/variants/ob-kill60/correctness/doris-offsets.txt
docker run --rm -v "$PWD:/workspace/project" -w /workspace/project/phase2/ob-kill60 \
  docker.io/apache/doris:build-env-ldb-toolchain-latest \
  bash -lc 'while read off; do echo "=== $off"; llvm-symbolizer -e be/output/lib/doris_be "$off"; done < /workspace/project/evidence/phase2/variants/ob-kill60/correctness/doris-offsets.txt' \
  > evidence/phase2/variants/ob-kill60/correctness/offline-symbolization.txt

# Patch export after committing the Doris worktree change.
mira-commit mira -m '[feature](be) Add ob-kill60 native stack collector' -- \
  be/src/service/http/action/native_stack_action.cpp
git -C phase2/ob-kill60 format-patch \
  --output-directory /home/mira/lab/projects/Doris-BE-Print-Stack-API-Research/patches/ob-kill60 \
  055bb465015fa6bcd61f9e33f352de78475fcc2e..HEAD
cp patches/ob-kill60/*.patch evidence/phase2/variants/ob-kill60/patches/
