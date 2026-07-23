#!/bin/bash
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
    echo "Error: App Intents metadata extraction requires macOS." >&2
    exit 2
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESOURCES_DIR="${1:-}"
MINIMUM_MACOS_VERSION="${MINIMUM_MACOS_VERSION:-14.0}"

if [ -z "$RESOURCES_DIR" ] || [ ! -d "$RESOURCES_DIR" ]; then
    echo "Error: pass an existing application Resources directory." >&2
    exit 2
fi

for command in xcodebuild xcode-select xcrun; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Error: required command is unavailable: $command" >&2
        exit 2
    fi
done
if ! xcrun --find appintentsmetadataprocessor >/dev/null 2>&1; then
    echo "Error: Xcode does not provide appintentsmetadataprocessor." >&2
    exit 2
fi

DEVELOPER_DIR="$(xcode-select -p)"
TOOLCHAIN_DIR="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain"
SDK_ROOT="$(xcrun --sdk macosx --show-sdk-path)"
XCODE_BUILD_VERSION="$(xcodebuild -version | awk '/Build version/ { print $3; exit }')"
if [ -z "$XCODE_BUILD_VERSION" ] || [ ! -d "$TOOLCHAIN_DIR" ] || [ ! -d "$SDK_ROOT" ]; then
    echo "Error: unable to resolve the active Xcode toolchain." >&2
    exit 2
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openfind-appintents.XXXXXX")"
DERIVED_DATA="$WORK_DIR/DerivedData"
METADATA_OUTPUT="$WORK_DIR/MetadataOutput"
PACKAGE_CACHE="$ROOT_DIR/.build/xcode-source-packages"

cleanup() {
    status=$?
    trap - EXIT INT TERM
    case "$WORK_DIR" in
        "${TMPDIR:-/tmp}"/openfind-appintents.*) /bin/rm -R "$WORK_DIR" ;;
        *) echo "Error: refusing to remove unexpected metadata work path: $WORK_DIR" >&2 ;;
    esac
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$PACKAGE_CACHE" "$METADATA_OUTPUT"
: > "$WORK_DIR/.metadata_never_index"

echo "Compiling static App Intents declarations..."
xcodebuild \
    -quiet \
    -scheme OpenFind \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$PACKAGE_CACHE" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    MACOSX_DEPLOYMENT_TARGET="$MINIMUM_MACOS_VERSION" \
    build

OBJECTS_DIR="$DERIVED_DATA/Build/Intermediates.noindex/OpenFind.build/Release/OpenFind.build/Objects-normal/arm64"
SOURCE_LIST="$OBJECTS_DIR/OpenFind.SwiftFileList"
CONST_VALUES="$OBJECTS_DIR/OpenFind-primary.swiftconstvalues"
if [ ! -s "$SOURCE_LIST" ] || [ ! -s "$CONST_VALUES" ]; then
    echo "Error: Xcode did not emit the inputs required for App Intents metadata." >&2
    exit 1
fi

CONST_VALUES_LIST="$WORK_DIR/SwiftConstValuesFileList"
printf '%s\n' "$CONST_VALUES" > "$CONST_VALUES_LIST"

echo "Extracting App Intents metadata..."
xcrun appintentsmetadataprocessor \
    --output "$METADATA_OUTPUT" \
    --toolchain-dir "$TOOLCHAIN_DIR" \
    --module-name OpenFind \
    --sdk-root "$SDK_ROOT" \
    --xcode-version "$XCODE_BUILD_VERSION" \
    --platform-family macOS \
    --deployment-target "$MINIMUM_MACOS_VERSION" \
    --target-triple "arm64-apple-macos$MINIMUM_MACOS_VERSION" \
    --source-file-list "$SOURCE_LIST" \
    --swift-const-vals-list "$CONST_VALUES_LIST" \
    --force \
    --deployment-aware-processing \
    --validate-assistant-intents \
    --no-app-shortcuts-localization

EXTRACTED_METADATA="$METADATA_OUTPUT/Metadata.appintents"
ACTION_DATA="$EXTRACTED_METADATA/extract.actionsdata"
VERSION_DATA="$EXTRACTED_METADATA/version.json"
if [ ! -s "$ACTION_DATA" ] || [ ! -s "$VERSION_DATA" ]; then
    echo "Error: App Intents metadata extraction produced an incomplete bundle." >&2
    exit 1
fi

for action in \
    ClearClipboardHistoryIntent \
    CopyClipboardItemIntent \
    CreateClipboardSnippetIntent \
    DeleteClipboardItemIntent \
    GetClipboardItemTextIntent \
    GetRecentClipboardItemsIntent \
    ShowClipboardHistoryIntent; do
    if ! grep -Fq "$action" "$ACTION_DATA"; then
        echo "Error: App Intents metadata is missing $action." >&2
        exit 1
    fi
done

TARGET_METADATA="$RESOURCES_DIR/Metadata.appintents"
if [ -e "$TARGET_METADATA" ] || [ -L "$TARGET_METADATA" ]; then
    /bin/rm -R "$TARGET_METADATA"
fi
ditto "$EXTRACTED_METADATA" "$TARGET_METADATA"
if [ ! -s "$TARGET_METADATA/extract.actionsdata" ] \
    || [ ! -s "$TARGET_METADATA/version.json" ]; then
    echo "Error: failed to install App Intents metadata into the application resources." >&2
    exit 1
fi

echo "OK: $TARGET_METADATA"
