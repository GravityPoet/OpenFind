#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

NODES="${NODES:-250000}"
MAX_LOAD_MS="${MAX_LOAD_MS:-5000}"
MAX_QUERY_MS="${MAX_QUERY_MS:-1000}"
MAX_RSS_MB="${MAX_RSS_MB:-768}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/openfind-name-index.XXXXXX")"

cleanup() {
    find "$TMP_ROOT" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

CACHE_PATH="$TMP_ROOT/search-index-v18.bin"

echo "Generating persisted name index: $NODES nodes..."
OPENFIND_NAME_BENCHMARK_CACHE="$CACHE_PATH" \
OPENFIND_NAME_BENCHMARK_NODES="$NODES" \
    xcrun --sdk macosx swift test -c release \
    --filter TemporarySearchPerformanceTests.generateConfiguredPersistedNameIndex

echo "Measuring mmap load and lossless query..."
OPENFIND_NAME_BENCHMARK_CACHE="$CACHE_PATH" \
OPENFIND_NAME_BENCHMARK_NODES="$NODES" \
OPENFIND_NAME_BENCHMARK_MAX_LOAD_MS="$MAX_LOAD_MS" \
OPENFIND_NAME_BENCHMARK_MAX_QUERY_MS="$MAX_QUERY_MS" \
OPENFIND_NAME_BENCHMARK_MAX_RSS_MB="$MAX_RSS_MB" \
    xcrun --sdk macosx swift test -c release --skip-build \
    --filter TemporarySearchPerformanceTests.measureConfiguredPersistedNameIndex

echo "OK: persisted name index stayed within load/query/RSS budgets"
