#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
build=${1:-"$root/build-asan"}

cmake -S "$root" -B "$build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug \
  -DBUILD_TESTING=ON \
  -DOMAFILES_ENABLE_ASAN=ON
cmake --build "$build" --target backend-safety-test
ASAN_OPTIONS=${ASAN_OPTIONS:-detect_leaks=1:halt_on_error=1} \
  ctest --test-dir "$build" --output-on-failure -R '^backend\.safety$'
