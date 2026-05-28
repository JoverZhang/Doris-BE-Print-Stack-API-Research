#!/usr/bin/env bash
set -euo pipefail

# Image used for all build/runtime commands.
IMAGE=docker.io/apache/doris:build-env-ldb-toolchain-latest
ROOT=/home/mira/lab/projects/Doris-BE-Print-Stack-API-Research
VARIANT=$ROOT/phase2/snapshot-remote-unwind
EVIDENCE=$ROOT/evidence/phase2/variants/snapshot-remote-unwind

# Worktree creation, from the common API commit.
git -C "$ROOT/repos/source/doris-master" worktree add \
  -b phase2-snapshot-remote-unwind \
  "$VARIANT" \
  055bb465015fa6bcd61f9e33f352de78475fcc2e

# Build attempts and final successful target verification.
docker run --rm \
  -v "$ROOT:/workspace/project" \
  -v "$ROOT:/home/mira/lab/projects/Doris-BE-Print-Stack-API-Research" \
  -w /workspace/project/phase2/snapshot-remote-unwind \
  "$IMAGE" \
  bash -lc 'set -o pipefail; DISABLE_BE_JAVA_EXTENSIONS=ON DISABLE_BE_CDC_CLIENT=ON ./build.sh --be -j 8'

docker run --rm \
  -v "$ROOT:/workspace/project" \
  -v "$ROOT:/home/mira/lab/projects/Doris-BE-Print-Stack-API-Research" \
  -w /workspace/project/phase2/snapshot-remote-unwind \
  "$IMAGE" \
  bash -lc 'set -o pipefail; cmake --build be/build_Release --target doris_be -j 8'

docker run --rm \
  -v "$ROOT:/workspace/project" \
  -v "$ROOT:/home/mira/lab/projects/Doris-BE-Print-Stack-API-Research" \
  -w /workspace/project/phase2/snapshot-remote-unwind \
  "$IMAGE" \
  bash -lc 'set -o pipefail; cmake --build be/build_Release --target doris_be -j 8 && cmake --build be/build_Release --target install -j 8'

# Runtime setup. The enable_java_support line is runtime-only in be/output/conf/be.conf.
mkdir -p "$VARIANT/be/output/www" "$VARIANT/be/output/storage" "$VARIANT/be/output/log"
cp -a "$VARIANT/webroot/be/." "$VARIANT/be/output/www/"

docker run -d --name doris-snapshot-remote-unwind-test -p 18047:8040 \
  -v "$ROOT:/workspace/project" \
  -v "$ROOT:/home/mira/lab/projects/Doris-BE-Print-Stack-API-Research" \
  -w /workspace/project/phase2/snapshot-remote-unwind \
  "$IMAGE" \
  bash -lc 'export JAVA_HOME=/usr/lib/jvm/jdk-17.0.2; export SKIP_CHECK_ULIMIT=true; unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY; be/output/bin/start_be.sh --console'

curl -fsS 'http://127.0.0.1:18047/api/health'

# Representative API evidence.
curl -fsS 'http://127.0.0.1:18047/api/debug/native_stack?timeout_ms=1000&max_frames=16&max_stack_bytes=8192' \
  -o "$EVIDENCE/api/all-threads.json"
curl -fsS 'http://127.0.0.1:18047/api/debug/native_stack?timeout_ms=3000&max_frames=16&max_stack_bytes=65536' \
  -o "$EVIDENCE/api/all-threads-64k.json"
curl -fsS 'http://127.0.0.1:18047/api/debug/native_stack?tid=736&timeout_ms=1000&max_frames=16&max_stack_bytes=8192' \
  -o "$EVIDENCE/api/one-tid.json"
curl -fsS 'http://127.0.0.1:18047/api/debug/native_stack?tid=999999999&timeout_ms=1000&max_frames=16&max_stack_bytes=8192' \
  -o "$EVIDENCE/api/missing-tid.json"
curl -fsS 'http://127.0.0.1:18047/api/debug/native_stack?timeout_ms=10&test_sleep_ms=50&max_frames=16&max_stack_bytes=8192' \
  -o "$EVIDENCE/api/timeout.json"

# Busy case: start one request with test_sleep_ms, then issue a second request.
curl -fsS 'http://127.0.0.1:18047/api/debug/native_stack?timeout_ms=1000&test_sleep_ms=800&max_frames=16&max_stack_bytes=8192' \
  -o "$EVIDENCE/api/busy-holder.json" &
holder_pid=$!
sleep 0.1
curl -fsS 'http://127.0.0.1:18047/api/debug/native_stack?timeout_ms=1000&max_frames=16&max_stack_bytes=8192' \
  -o "$EVIDENCE/api/busy.json"
wait "$holder_pid" || true

# Correctness material.
docker exec doris-snapshot-remote-unwind-test bash -lc \
  'pid=$(pgrep -f "be/output/lib/doris_be" | head -1); cat /proc/$pid/maps' \
  > "$EVIDENCE/correctness/maps.txt"
jq -r '.threads[].frames[] | select(.dso|endswith("/doris_be")) | .dso_offset' \
  "$EVIDENCE/api/all-threads.json" | sort -u | head -20 \
  > "$EVIDENCE/correctness/doris-offsets.txt"
docker exec -i doris-snapshot-remote-unwind-test bash -lc \
  'while read off; do echo "=== $off"; llvm-symbolizer -e be/output/lib/doris_be "$off" || true; done' \
  < "$EVIDENCE/correctness/doris-offsets.txt" \
  > "$EVIDENCE/correctness/offline-symbolization.txt"

# Patch export.
git -C "$VARIANT" format-patch \
  --output-directory "$ROOT/patches/snapshot-remote-unwind" \
  055bb465015fa6bcd61f9e33f352de78475fcc2e..HEAD
cp "$ROOT"/patches/snapshot-remote-unwind/*.patch "$EVIDENCE/patches/"
