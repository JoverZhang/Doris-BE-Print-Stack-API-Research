#!/usr/bin/env bash
set -euo pipefail

# Audit script for the source-build blocker recorded for task #23.
# It intentionally does not run an unbounded recursive submodule checkout.

echo "Attempt 1: git clone --recursive --depth 1 --branch v26.3.10.62-lts https://github.com/ClickHouse/ClickHouse.git <scheme>/.cache/ClickHouse-v26.3.10.62-lts"
echo "Observed before manual stop: about 7 minutes elapsed, about 4.7G cache size, active submodule contrib/google-cloud-cpp, 129 submodules still uninitialized/not clean."
echo
echo "Attempt 2/3 CMake command:"
echo "cmake -S <ClickHouse source> -B <scheme>/build/probe -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DENABLE_TESTS=OFF -DENABLE_CLICKHOUSE_ALL=OFF -DENABLE_CLICKHOUSE_KEEPER=OFF -DENABLE_CLICKHOUSE_KEEPER_CONVERTER=OFF -DENABLE_CLICKHOUSE_KEEPER_CLIENT=OFF -DENABLE_THINLTO=OFF"
echo
echo "CMake error summary:"
echo "CMake Error at CMakeLists.txt:59 (message):"
echo "  Submodules are not initialized.  Run"
echo
echo "      git submodule update --init"
