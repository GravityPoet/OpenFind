#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BASE_TMP="${TMPDIR:-/tmp}"
BASE_TMP="${BASE_TMP%/}"
TEST_ROOT="$(mktemp -d "$BASE_TMP/openfind-tests.XXXXXX")"
TEST_HOME="$TEST_ROOT/home"
TEST_TMP="$TEST_ROOT/tmp"

cleanup() {
    status=$?
    trap - EXIT INT TERM
    case "$TEST_ROOT" in
        "$BASE_TMP"/openfind-tests.*)
            if [ -d "$TEST_ROOT" ]; then
                /bin/rm -R "$TEST_ROOT"
            fi
            ;;
        *)
            echo "Error: refusing to clean unexpected test path: $TEST_ROOT" >&2
            status=64
            ;;
    esac
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$TEST_HOME" "$TEST_TMP"
export HOME="$TEST_HOME"
export CFFIXED_USER_HOME="$TEST_HOME"
export TMPDIR="$TEST_TMP"
export OPENFIND_TEST_MODE=1

cd "$ROOT_DIR"
if [ -n "${OPENFIND_TEST_SCRATCH_PATH:-}" ]; then
    xcrun --sdk macosx swift test \
        --scratch-path "$OPENFIND_TEST_SCRATCH_PATH" \
        --no-parallel \
        "$@"
else
    xcrun --sdk macosx swift test --no-parallel "$@"
fi
