#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BASE_TMP="${TMPDIR:-/tmp}"
BASE_TMP="${BASE_TMP%/}"
TEST_ROOT="$(mktemp -d "$BASE_TMP/openfind-tests.XXXXXX")"
TEST_HOME="$TEST_ROOT/home"
TEST_TMP="$TEST_ROOT/tmp"

cleanup() {
    test_exit_code=$?
    trap - EXIT INT TERM
    case "$TEST_ROOT" in
        "$BASE_TMP"/openfind-tests.*)
            if [ -d "$TEST_ROOT" ]; then
                /bin/rm -R "$TEST_ROOT"
            fi
            ;;
        *)
            echo "Error: refusing to clean unexpected test path: $TEST_ROOT" >&2
            test_exit_code=64
            ;;
    esac
    exit "$test_exit_code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$TEST_HOME" "$TEST_TMP"
export TMPDIR="$TEST_TMP"
export OPENFIND_TEST_MODE=1

cd "$ROOT_DIR"
# Build the test bundle before applying the isolated Foundation home. Xcode
# may mount its read-only Metal toolchain below CFFIXED_USER_HOME while it
# resolves/builds Swift packages; that mount must stay outside TEST_ROOT.
unset CFFIXED_USER_HOME
build_args=()
skip_build_arg=0
for test_arg in "$@"; do
    if [ "$skip_build_arg" -eq 1 ]; then
        skip_build_arg=0
        continue
    fi
    case "$test_arg" in
        # Benchmark wrappers pass --skip-build to reuse the generated release
        # bundle for their measurement phases. The preparation phase must
        # still build that configuration.
        --skip-build|-l|--list-tests|--no-parallel|--parallel)
            continue
            ;;
        # These options select test execution and are not accepted by the
        # `swift test list` compatibility command used for preparation.
        --filter|--skip|--specifier|--num-workers|--attachments-path)
            skip_build_arg=1
            continue
            ;;
        --filter=*|--skip=*|--specifier=*|--num-workers=*|--attachments-path=*)
            continue
            ;;
        *)
            build_args+=("$test_arg")
            ;;
    esac
done
if [ -n "${OPENFIND_TEST_SCRATCH_PATH:-}" ]; then
    xcrun --sdk macosx swift test \
        --scratch-path "$OPENFIND_TEST_SCRATCH_PATH" \
        "${build_args[@]}" \
        --list-tests > "$TEST_ROOT/list-tests.log"
else
    xcrun --sdk macosx swift test \
        "${build_args[@]}" \
        --list-tests > "$TEST_ROOT/list-tests.log"
fi

# Keep the tested process' user-domain state disposable while reusing the
# already-built test bundle. Foundation resolves NSHomeDirectory and related
# paths from CFFIXED_USER_HOME, without changing Xcode's build-time home.
export CFFIXED_USER_HOME="$TEST_HOME"
if [ -n "${OPENFIND_TEST_SCRATCH_PATH:-}" ]; then
    xcrun --sdk macosx swift test \
        --scratch-path "$OPENFIND_TEST_SCRATCH_PATH" \
        --skip-build \
        --no-parallel \
        "$@"
else
    xcrun --sdk macosx swift test --skip-build --no-parallel "$@"
fi
