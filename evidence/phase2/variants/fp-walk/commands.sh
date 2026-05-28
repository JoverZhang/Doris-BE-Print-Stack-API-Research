#!/usr/bin/env bash
set -euo pipefail

# Build image used for all commands:
# docker.io/apache/doris:build-env-ldb-toolchain-latest

# Full build. This linked and installed be/output/lib/doris_be, then failed only
# during build.sh root output packaging because cp -p cannot preserve permissions
# on this bind mount. See build-output/build-sh.txt.
docker run --rm \
  -v "$PWD:/workspace/project" \
  -v "$PWD:/home/mira/lab/projects/Doris-BE-Print-Stack-API-Research" \
  -w /workspace/project/phase2/fp-walk \
  docker.io/apache/doris:build-env-ldb-toolchain-latest \
  bash -lc 'set -o pipefail; DISABLE_BE_JAVA_EXTENSIONS=ON DISABLE_BE_CDC_CLIENT=ON ./build.sh --be -j 8'

# Successful target verification after the build.
docker run --rm \
  -v "$PWD:/workspace/project" \
  -v "$PWD:/home/mira/lab/projects/Doris-BE-Print-Stack-API-Research" \
  -w /workspace/project/phase2/fp-walk \
  docker.io/apache/doris:build-env-ldb-toolchain-latest \
  bash -lc 'cmake --build be/build_Release --target doris_be -j 8'

# Runtime setup used for local standalone BE smoke.
mkdir -p phase2/fp-walk/be/output/www phase2/fp-walk/be/output/storage phase2/fp-walk/be/output/log
cp -a phase2/fp-walk/webroot/be/. phase2/fp-walk/be/output/www/
# Runtime-only conf line:
# enable_java_support = false

docker run -d --name doris-fp-walk-test -p 18041:8040 \
  -v "$PWD:/workspace/project" \
  -v "$PWD:/home/mira/lab/projects/Doris-BE-Print-Stack-API-Research" \
  -w /workspace/project/phase2/fp-walk \
  docker.io/apache/doris:build-env-ldb-toolchain-latest \
  bash -lc 'export JAVA_HOME=/usr/lib/jvm/jdk-17.0.2; export SKIP_CHECK_ULIMIT=true; unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY; be/output/bin/start_be.sh --console'

# Representative API commands.
curl -fsS 'http://127.0.0.1:18041/api/debug/native_stack?timeout_ms=1000&max_frames=16'
curl -fsS 'http://127.0.0.1:18041/api/debug/native_stack?tid=2523&timeout_ms=1000&max_frames=16'
curl -fsS 'http://127.0.0.1:18041/api/debug/native_stack?tid=999999999&timeout_ms=1000&max_frames=16'
curl -fsS 'http://127.0.0.1:18041/api/debug/native_stack?timeout_ms=10&test_sleep_ms=50'

# Offline symbolization command.
docker run --rm -v "$PWD:/workspace/project" -w /workspace/project/phase2/fp-walk \
  docker.io/apache/doris:build-env-ldb-toolchain-latest \
  bash -lc 'while read off; do echo === $off; llvm-symbolizer -e be/output/lib/doris_be $off; done < /workspace/project/evidence/phase2/variants/fp-walk/correctness/known-stack-doris-offsets.txt'
