#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

FILES="${FILES:-8000}"
BODY_KB="${BODY_KB:-16}"
COPIES="${COPIES:-4}"

# The Swift benchmark creates only generated temporary text and removes its
# entire directory with `defer`, including failures. It never clones or scans
# the user's real filesystem.
OPENFIND_CONTENT_BENCHMARK_FILES="$FILES" \
OPENFIND_CONTENT_BENCHMARK_KB="$BODY_KB" \
OPENFIND_CONTENT_BENCHMARK_COPIES="$COPIES" \
    xcrun --sdk macosx swift test -c release \
    --filter TemporarySearchPerformanceTests.measureGeneratedContentIndex
