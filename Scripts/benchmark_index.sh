#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

FILES="${FILES:-3000}"
MATCH_EVERY="${MATCH_EVERY:-100}"
MAX_REFRESH_MS="${MAX_REFRESH_MS:-5000}"
MAX_SEARCH_MS="${MAX_SEARCH_MS:-1000}"
MAX_FLUSH_MS="${MAX_FLUSH_MS:-5000}"
MAX_RSS_MB="${MAX_RSS_MB:-768}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/openfind-benchmark.XXXXXX")"

cleanup() {
    find "$TMP_ROOT" -depth -delete 2>/dev/null || true
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
BIN_DIR="$(xcrun --sdk macosx swift build -c release --show-bin-path)"
OPENFIND_BINARY="$BIN_DIR/OpenFind"
test -x "$OPENFIND_BINARY"
/usr/bin/time -l env HOME="$BENCH_HOME" OPENFIND_CACHE_PATH="$CACHE_PATH" \
    "$OPENFIND_BINARY" --search benchneedle "$TREE_ROOT" --refresh --timing \
    >"$OUTPUT" 2>"$TIMING"

actual="$(wc -l < "$OUTPUT" | tr -d ' ')"
if [ "$actual" -ne "$expected" ]; then
    echo "Error: expected $expected results, got $actual" >&2
    echo "Timing output:" >&2
    cat "$TIMING" >&2
    exit 1
fi

refresh_ms="$(sed -n 's/^timing refresh=\([0-9][0-9]*\)ms$/\1/p' "$TIMING" | tail -n 1)"
search_ms="$(sed -n 's/^timing search=\([0-9][0-9]*\)ms$/\1/p' "$TIMING" | tail -n 1)"
flush_ms="$(sed -n 's/^timing flush=\([0-9][0-9]*\)ms$/\1/p' "$TIMING" | tail -n 1)"
rss_bytes="$(awk '/maximum resident set size/ { value=$1 } END { print value }' "$TIMING")"

if [ -z "$refresh_ms" ] || [ -z "$search_ms" ] || [ -z "$flush_ms" ] || [ -z "$rss_bytes" ]; then
    echo "Error: benchmark did not emit every required timing/RSS metric" >&2
    cat "$TIMING" >&2
    exit 1
fi
if [ "$refresh_ms" -gt "$MAX_REFRESH_MS" ] || \
   [ "$search_ms" -gt "$MAX_SEARCH_MS" ] || \
   [ "$flush_ms" -gt "$MAX_FLUSH_MS" ] || \
   [ "$rss_bytes" -gt $((MAX_RSS_MB * 1024 * 1024)) ]; then
    echo "Error: cold index benchmark exceeded its performance budget" >&2
    echo "refresh=${refresh_ms}ms search=${search_ms}ms flush=${flush_ms}ms rss=${rss_bytes}" >&2
    exit 1
fi

echo "cold-index refresh=${refresh_ms}ms search=${search_ms}ms flush=${flush_ms}ms peak-rss=${rss_bytes}"
echo "OK: benchmark matched $actual / $FILES files within cold-index budgets"
