#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

FILES="${FILES:-3000}"
MATCH_EVERY="${MATCH_EVERY:-100}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/openfind-benchmark.XXXXXX")"

cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

BENCH_HOME="$TMP_ROOT/home"
TREE_ROOT="$TMP_ROOT/tree"
CACHE_PATH="$TMP_ROOT/search-index.bin"
OUTPUT="$TMP_ROOT/results.txt"
TIMING="$TMP_ROOT/timing.txt"
mkdir -p "$BENCH_HOME/Library/Application Support" "$TREE_ROOT"

echo "Preparing benchmark tree: $FILES files..."
index=0
while [ "$index" -lt "$FILES" ]; do
    folder="$TREE_ROOT/folder-$((index / 100))"
    mkdir -p "$folder"
    if [ $((index % MATCH_EVERY)) -eq 0 ]; then
        name="benchneedle-$index.txt"
    else
        name="noise-$index.txt"
    fi
    printf 'OpenFind benchmark file %s\n' "$index" > "$folder/$name"
    index=$((index + 1))
done

expected=$(((FILES + MATCH_EVERY - 1) / MATCH_EVERY))

echo "Running indexed name-search benchmark..."
HOME="$BENCH_HOME" OPENFIND_CACHE_PATH="$CACHE_PATH" xcrun --sdk macosx swift run -c release OpenFind \
    --search benchneedle "$TREE_ROOT" --refresh --timing \
    >"$OUTPUT" 2>"$TIMING"

actual="$(wc -l < "$OUTPUT" | tr -d ' ')"
if [ "$actual" -ne "$expected" ]; then
    echo "Error: expected $expected results, got $actual" >&2
    echo "Timing output:" >&2
    cat "$TIMING" >&2
    exit 1
fi

cat "$TIMING"
echo "OK: benchmark matched $actual / $FILES files"
