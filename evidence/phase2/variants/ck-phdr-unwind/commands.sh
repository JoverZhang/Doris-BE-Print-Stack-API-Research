#!/usr/bin/env bash
set -euo pipefail

# Build image used for all Doris build/runtime commands:
# docker.io/apache/doris:build-env-ldb-toolchain-latest

# Create the variant worktree from the common API commit.
git -C phase2/common-api worktree add \
  -b phase2-ck-phdr-unwind \
  ../ck-phdr-unwind \
  055bb465015fa6bcd61f9e33f352de78475fcc2e

# Initial build attempt before the UNW_LOCAL_ONLY fix failed at final link with
# undefined _Ux86_64_* libunwind references. Its log was preserved before rerun.
docker run --rm \
  -v "$PWD:/workspace/project" \
  -v "$PWD:/home/mira/lab/projects/Doris-BE-Print-Stack-API-Research" \
  -w /workspace/project/phase2/ck-phdr-unwind \
  docker.io/apache/doris:build-env-ldb-toolchain-latest \
  bash -lc 'set -o pipefail; DISABLE_BE_JAVA_EXTENSIONS=ON DISABLE_BE_CDC_CLIENT=ON ./build.sh --be -j 8 2>&1 | tee /workspace/project/evidence/phase2/variants/ck-phdr-unwind/build-output/build-sh.txt'
cp evidence/phase2/variants/ck-phdr-unwind/build-output/build-sh.txt \
  evidence/phase2/variants/ck-phdr-unwind/build-output/build-sh-link-failure.txt

# Required target verification after the libunwind local-only fix.
docker run --rm \
  -v "$PWD:/workspace/project" \
  -v "$PWD:/home/mira/lab/projects/Doris-BE-Print-Stack-API-Research" \
  -w /workspace/project/phase2/ck-phdr-unwind \
  docker.io/apache/doris:build-env-ldb-toolchain-latest \
  bash -lc 'set -o pipefail; cmake --build be/build_Release --target doris_be -j 8 2>&1 | tee /workspace/project/evidence/phase2/variants/ck-phdr-unwind/build-output/ninja-doris_be.txt'

# Full BE build after the fix. This compiled and installed
# be/output/lib/doris_be, then failed only during final root output packaging
# because cp -p cannot preserve permissions on this bind mount. See
# build-output/build-sh.txt.
docker run --rm \
  -v "$PWD:/workspace/project" \
  -v "$PWD:/home/mira/lab/projects/Doris-BE-Print-Stack-API-Research" \
  -w /workspace/project/phase2/ck-phdr-unwind \
  docker.io/apache/doris:build-env-ldb-toolchain-latest \
  bash -lc 'set -o pipefail; DISABLE_BE_JAVA_EXTENSIONS=ON DISABLE_BE_CDC_CLIENT=ON ./build.sh --be -j 8 2>&1 | tee /workspace/project/evidence/phase2/variants/ck-phdr-unwind/build-output/build-sh.txt'

# Runtime setup used for standalone BE smoke testing. These are runtime output
# files only and are not part of the Doris source commit.
mkdir -p phase2/ck-phdr-unwind/be/output/www \
  phase2/ck-phdr-unwind/be/output/storage \
  phase2/ck-phdr-unwind/be/output/log
cp -a phase2/ck-phdr-unwind/webroot/be/. phase2/ck-phdr-unwind/be/output/www/
cat >> phase2/ck-phdr-unwind/be/output/conf/be.conf <<'EOF_CONF'

# ck-phdr-unwind runtime smoke override
enable_java_support = false
storage_root_path = ${DORIS_HOME}/storage
EOF_CONF

# Port 18042 was already occupied by another variant, so this run used 18043.
docker run -d --name doris-ck-phdr-unwind-test -p 18043:8040 \
  -v "$PWD:/workspace/project" \
  -v "$PWD:/home/mira/lab/projects/Doris-BE-Print-Stack-API-Research" \
  -w /workspace/project/phase2/ck-phdr-unwind \
  docker.io/apache/doris:build-env-ldb-toolchain-latest \
  bash -lc 'export JAVA_HOME=/usr/lib/jvm/jdk-17.0.2; export SKIP_CHECK_ULIMIT=true; unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY; be/output/bin/start_be.sh --console'

curl -fsS 'http://127.0.0.1:18043/api/health'

# Representative API evidence.
curl -fsS 'http://127.0.0.1:18043/api/debug/native_stack?timeout_ms=1000&max_frames=16' \
  | jq . > evidence/phase2/variants/ck-phdr-unwind/api/all-threads.json
tid=$(jq -r 'first(.threads[]? | select((.frames // []) | length > 0) | .tid) // first(.threads[]?.tid)' \
  evidence/phase2/variants/ck-phdr-unwind/api/all-threads.json)
printf '%s\n' "$tid" > evidence/phase2/variants/ck-phdr-unwind/api/target-tid.txt
curl -fsS "http://127.0.0.1:18043/api/debug/native_stack?tid=$tid&timeout_ms=1000&max_frames=16" \
  | jq . > evidence/phase2/variants/ck-phdr-unwind/api/one-tid.json
curl -fsS 'http://127.0.0.1:18043/api/debug/native_stack?tid=999999999&timeout_ms=1000&max_frames=16' \
  | jq . > evidence/phase2/variants/ck-phdr-unwind/api/missing-tid.json
curl -fsS 'http://127.0.0.1:18043/api/debug/native_stack?timeout_ms=10&test_sleep_ms=50' \
  | jq . > evidence/phase2/variants/ck-phdr-unwind/api/timeout.json
(
  curl -fsS 'http://127.0.0.1:18043/api/debug/native_stack?timeout_ms=5000&test_sleep_ms=2000&max_frames=8' \
    | jq . > evidence/phase2/variants/ck-phdr-unwind/api/busy-holder.json
) &
holder_pid=$!
sleep 0.2
curl -fsS 'http://127.0.0.1:18043/api/debug/native_stack?timeout_ms=1000&max_frames=8' \
  | jq . > evidence/phase2/variants/ck-phdr-unwind/api/busy.json
wait "$holder_pid"

jq -r '[inputs as $in | $in | .. | objects | keys[]? | select(. == "symbol" or . == "function" or . == "file" or . == "line" or . == "symbol_name")] | unique | if length == 0 then "PASS no symbol/function/file/line/symbol_name keys" else "FAIL forbidden keys: " + (join(",")) end' \
  /dev/null \
  evidence/phase2/variants/ck-phdr-unwind/api/all-threads.json \
  evidence/phase2/variants/ck-phdr-unwind/api/one-tid.json \
  evidence/phase2/variants/ck-phdr-unwind/api/busy.json \
  evidence/phase2/variants/ck-phdr-unwind/api/timeout.json \
  evidence/phase2/variants/ck-phdr-unwind/api/missing-tid.json \
  > evidence/phase2/variants/ck-phdr-unwind/api/no-symbol-check.txt

# Correctness evidence.
docker exec doris-ck-phdr-unwind-test bash -lc 'pid=""; for d in /proc/[0-9]*; do if [ -r "$d/comm" ] && [ "$(cat "$d/comm")" = "doris_be" ]; then pid=${d#/proc/}; break; fi; done; echo "pid=$pid"; cat /proc/$pid/maps' \
  > evidence/phase2/variants/ck-phdr-unwind/correctness/maps.txt

jq -r '[.threads[].frames[]? | select((.dso // "") | endswith("/doris_be")) | .dso_offset] | unique | .[0:80][]' \
  evidence/phase2/variants/ck-phdr-unwind/api/all-threads.json \
  > evidence/phase2/variants/ck-phdr-unwind/correctness/doris-offsets.txt
docker run --rm -v "$PWD:/workspace/project" \
  -w /workspace/project/phase2/ck-phdr-unwind \
  docker.io/apache/doris:build-env-ldb-toolchain-latest \
  bash -lc 'offsets=/workspace/project/evidence/phase2/variants/ck-phdr-unwind/correctness/doris-offsets.txt; echo "binary: be/output/lib/doris_be"; echo "offset_count: $(wc -l < "$offsets")"; while read -r off; do echo "=== $off"; llvm-symbolizer -e be/output/lib/doris_be "$off" | sed -n "1,4p"; done < "$offsets"' \
  > evidence/phase2/variants/ck-phdr-unwind/correctness/offline-symbolization.txt

# Repeat evidence was generated by a 50-iteration loop against:
# /api/debug/native_stack?timeout_ms=1000&max_frames=8

# Commit and patch export.
git -C phase2/ck-phdr-unwind add be/src/service/http/action/native_stack_action.cpp
/home/mira/lab/workflow/bin/mira-commit mira -m '[feature](be) Add ck phdr unwind native stack collector' -- \
  be/src/service/http/action/native_stack_action.cpp
git -C phase2/ck-phdr-unwind format-patch \
  055bb465015fa6bcd61f9e33f352de78475fcc2e..HEAD \
  --output-directory ../../patches/ck-phdr-unwind
cp patches/ck-phdr-unwind/*.patch evidence/phase2/variants/ck-phdr-unwind/patches/
