#!/bin/bash
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
    echo "Error: this builder requires macOS." >&2
    exit 2
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

ARCHS="${ARCHS:-arm64 x86_64}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
SIGN_TIMESTAMP="${SIGN_TIMESTAMP:-0}"
DISTRIBUTION="${DISTRIBUTION:-direct}"
ENTITLEMENTS="${ENTITLEMENTS:-}"
ENTITLEMENTS_EXPLICIT=0
if [ -n "$ENTITLEMENTS" ]; then
    ENTITLEMENTS_EXPLICIT=1
fi
NOTARIZE="${NOTARIZE:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_KEYCHAIN="${NOTARY_KEYCHAIN:-}"
STORE_NOTARY_CREDENTIALS="${STORE_NOTARY_CREDENTIALS:-0}"
MINIMUM_MACOS_VERSION="${MINIMUM_MACOS_VERSION:-14.0}"
APP_VERSION="${APP_VERSION:-1.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-2}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-}"
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"
EXPECTED_SIGNING_CERT_SHA1="${EXPECTED_SIGNING_CERT_SHA1:-}"

if [ -z "$SIGN_IDENTITY" ]; then
    echo "Error: SIGN_IDENTITY is required. Use Scripts/build_customer_app.sh for product builds or set SIGN_IDENTITY=- explicitly for an ad-hoc validation build." >&2
    exit 2
fi

APP_NAME="OpenFind.app"
BUNDLE_ID="com.openfind.app"
DIST_DIR="$ROOT_DIR/dist"
ARCHIVE_PATH="$DIST_DIR/OpenFind.zip"
CHECKSUM_PATH="$DIST_DIR/OpenFind.zip.sha256"
STALE_APP="$DIST_DIR/$APP_NAME"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

case "$DISTRIBUTION" in
    direct|customer|developer-id)
        DEFAULT_ENTITLEMENTS="Entitlements/OpenFind.direct.entitlements"
        ;;
    sandbox|appstore)
        DEFAULT_ENTITLEMENTS="Entitlements/OpenFind.sandbox.entitlements"
        ;;
    *)
        echo "Error: DISTRIBUTION must be direct, customer, developer-id, sandbox, or appstore" >&2
        exit 2
        ;;
esac

if [ "$DISTRIBUTION" = "customer" ]; then
    if [ -z "$EXPECTED_SIGNING_CERT_SHA1" ]; then
        echo "Error: customer builds must pin EXPECTED_SIGNING_CERT_SHA1." >&2
        exit 2
    fi
    if [ "$NOTARIZE" = "1" ]; then
        echo "Error: self-signed customer builds cannot use Apple notarization." >&2
        exit 2
    fi
fi

if [ -z "$ENTITLEMENTS" ]; then
    ENTITLEMENTS="$DEFAULT_ENTITLEMENTS"
fi
if [ ! -f "$ENTITLEMENTS" ]; then
    echo "Error: entitlements file not found: $ENTITLEMENTS" >&2
    exit 2
fi

BUILD_TMP="$(mktemp -d "${TMPDIR:-/tmp}/openfind-build.XXXXXX")"
APP_DIR="$BUILD_TMP/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
ARCHIVE_TMP="$DIST_DIR/.OpenFind.zip.tmp.$$"
CHECKSUM_TMP="$DIST_DIR/.OpenFind.zip.sha256.tmp.$$"

remove_known_tree() {
    local target="$1"
    case "$target" in
        "$BUILD_TMP"|"$STALE_APP") ;;
        *)
            echo "Error: refusing to remove unexpected build path: $target" >&2
            return 64
            ;;
    esac
    if [ -e "$target" ] || [ -L "$target" ]; then
        /bin/rm -R "$target"
    fi
}

cleanup() {
    status=$?
    trap - EXIT INT TERM
    if [ -d "$APP_DIR/Contents" ]; then
        while IFS= read -r -d '' nested_app; do
            "$LSREGISTER" -u "$nested_app" >/dev/null 2>&1 || true
        done < <(find "$APP_DIR/Contents" -type d -name '*.app' -prune -print0 2>/dev/null)
    fi
    "$LSREGISTER" -u "$APP_DIR" >/dev/null 2>&1 || true
    remove_known_tree "$BUILD_TMP"
    /bin/rm -f "$ARCHIVE_TMP"
    /bin/rm -f "$CHECKSUM_TMP"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

: > "$BUILD_TMP/.metadata_never_index"
mkdir -p "$ROOT_DIR/.build"
: > "$ROOT_DIR/.build/.metadata_never_index"
mkdir -p "$DIST_DIR"

if [ -d "$STALE_APP" ]; then
    "$LSREGISTER" -u "$STALE_APP" >/dev/null 2>&1 || true
    remove_known_tree "$STALE_APP"
fi
/bin/rm -f "$ARCHIVE_PATH" "$CHECKSUM_PATH" "$ARCHIVE_TMP" "$CHECKSUM_TMP"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"
export MACOSX_DEPLOYMENT_TARGET="$MINIMUM_MACOS_VERSION"

if { [ -n "$SPARKLE_FEED_URL" ] && [ -z "$SPARKLE_PUBLIC_KEY" ]; } \
    || { [ -z "$SPARKLE_FEED_URL" ] && [ -n "$SPARKLE_PUBLIC_KEY" ]; }; then
    echo "Error: SPARKLE_FEED_URL and SPARKLE_PUBLIC_KEY must be provided together." >&2
    exit 2
fi
if [ -n "$SPARKLE_FEED_URL" ]; then
    case "$SPARKLE_FEED_URL" in
        https://*) ;;
        *)
            echo "Error: SPARKLE_FEED_URL must use HTTPS." >&2
            exit 2
            ;;
    esac
fi

echo "Generating application icon..."
swift Scripts/make_icon.swift "$BUILD_TMP/OpenFind.icns" "$BUILD_TMP/OpenFind.iconset"

BINARIES=()
for arch in $ARCHS; do
    echo "Building Release executable for $arch..."
    xcrun --sdk macosx swift build -c release --arch "$arch"
    BIN_PATH="$(xcrun --sdk macosx swift build -c release --arch "$arch" --show-bin-path)"
    ARCH_BINARY="$BUILD_TMP/OpenFind-$arch"
    cp "$BIN_PATH/OpenFind" "$ARCH_BINARY"
    BINARIES+=("$ARCH_BINARY")

done

if [ "${#BINARIES[@]}" -gt 1 ]; then
    echo "Creating universal executable..."
    lipo -create "${BINARIES[@]}" -output "$MACOS_DIR/OpenFind"
else
    cp "${BINARIES[0]}" "$MACOS_DIR/OpenFind"
fi
chmod +x "$MACOS_DIR/OpenFind"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$MACOS_DIR/OpenFind"

echo "Copying standard application localizations..."
cp -R Sources/OpenFind/Resources/en.lproj "$RESOURCES_DIR/"
cp -R Sources/OpenFind/Resources/zh-Hans.lproj "$RESOURCES_DIR/"
cp Sources/OpenFind/Resources/OpenFind.sdef "$RESOURCES_DIR/"

SPARKLE_FRAMEWORK="$(find "$ROOT_DIR/.build/artifacts" \
    -path '*/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework' \
    -type d -print -quit 2>/dev/null || true)"
if [ -z "$SPARKLE_FRAMEWORK" ]; then
    echo "Error: Sparkle.framework was not resolved by SwiftPM." >&2
    exit 1
fi
echo "Embedding Sparkle.framework..."
ditto "$SPARKLE_FRAMEWORK" "$FRAMEWORKS_DIR/Sparkle.framework"

mv "$BUILD_TMP/OpenFind.icns" "$RESOURCES_DIR/"
echo "APPL????" > "$CONTENTS_DIR/PkgInfo"
cp Info.plist "$CONTENTS_DIR/Info.plist"
plutil -replace LSMinimumSystemVersion -string "$MINIMUM_MACOS_VERSION" "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$CONTENTS_DIR/Info.plist"
if [ -n "$SPARKLE_FEED_URL" ]; then
    plutil -insert SUFeedURL -string "$SPARKLE_FEED_URL" "$CONTENTS_DIR/Info.plist"
    plutil -insert SUPublicEDKey -string "$SPARKLE_PUBLIC_KEY" "$CONTENTS_DIR/Info.plist"
    plutil -insert SUEnableAutomaticChecks -bool true "$CONTENTS_DIR/Info.plist"
fi

echo "Signing the application bundle..."
if [ "$DISTRIBUTION" = "customer" ] && [ "$SIGN_IDENTITY" = "-" ]; then
    echo "Error: customer builds must not use ad-hoc signing." >&2
    exit 2
fi
if [ "$ENTITLEMENTS_EXPLICIT" -eq 0 ] \
    && { [ "$DISTRIBUTION" = "direct" ] || [ "$DISTRIBUTION" = "customer" ]; } \
    && [[ "$SIGN_IDENTITY" != "Developer ID Application:"* ]]; then
    # Self-signed identities have no Apple Team ID. Hardened runtime
    # would otherwise reject the embedded Sparkle framework even after both
    # are signed by the same local certificate. Developer ID builds retain
    # strict library validation through the empty direct entitlements file.
    ENTITLEMENTS="Entitlements/OpenFind.local.entitlements"
fi
if [ ! -f "$ENTITLEMENTS" ]; then
    echo "Error: entitlements file not found: $ENTITLEMENTS" >&2
    exit 2
fi
CODESIGN_ARGS=(--force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY")
NESTED_CODESIGN_ARGS=(
    --force
    --deep
    --options runtime
    --preserve-metadata=identifier,entitlements
    --sign "$SIGN_IDENTITY"
)
if [ "$SIGN_TIMESTAMP" = "1" ]; then
    CODESIGN_ARGS+=(--timestamp)
    NESTED_CODESIGN_ARGS+=(--timestamp)
fi
codesign "${NESTED_CODESIGN_ARGS[@]}" "$FRAMEWORKS_DIR/Sparkle.framework"
codesign "${CODESIGN_ARGS[@]}" "$APP_DIR"

if [ -n "$EXPECTED_SIGNING_CERT_SHA1" ]; then
    EXPECTED_SIGNING_CERT_SHA1="$(printf '%s' "$EXPECTED_SIGNING_CERT_SHA1" | tr '[:upper:]' '[:lower:]')"
    SIGNING_REQUIREMENT="$(codesign -d -r- "$APP_DIR" 2>&1)"
    if ! printf '%s\n' "$SIGNING_REQUIREMENT" \
        | tr '[:upper:]' '[:lower:]' \
        | grep -Fq "certificate leaf = h\"$EXPECTED_SIGNING_CERT_SHA1\""; then
        echo "Error: app was not signed by the pinned customer certificate." >&2
        exit 1
    fi
fi

if [ "$NOTARIZE" = "1" ]; then
    case "$SIGN_IDENTITY" in
        "Developer ID Application:"*) ;;
        *)
            echo "Error: NOTARIZE=1 requires a Developer ID Application identity" >&2
            exit 2
            ;;
    esac

    NOTARY_ZIP="$BUILD_TMP/OpenFind-notary.zip"
    echo "Creating notarization archive..."
    ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$NOTARY_ZIP"

    if [ -z "$NOTARY_PROFILE" ]; then
        NOTARY_PROFILE="openfind-notary"
    fi
    if [ "$STORE_NOTARY_CREDENTIALS" = "1" ]; then
        : "${APPLE_ID:?APPLE_ID is required when STORE_NOTARY_CREDENTIALS=1}"
        : "${TEAM_ID:?TEAM_ID is required when STORE_NOTARY_CREDENTIALS=1}"
        : "${APP_SPECIFIC_PASSWORD:?APP_SPECIFIC_PASSWORD is required when STORE_NOTARY_CREDENTIALS=1}"
        echo "Storing notarization credentials in keychain profile: $NOTARY_PROFILE"
        STORE_NOTARY_ARGS=(
            --apple-id "$APPLE_ID"
            --team-id "$TEAM_ID"
            --password "$APP_SPECIFIC_PASSWORD"
        )
        if [ -n "$NOTARY_KEYCHAIN" ]; then
            STORE_NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN")
        fi
        xcrun notarytool store-credentials \
            "$NOTARY_PROFILE" "${STORE_NOTARY_ARGS[@]}"
    fi

    echo "Submitting notarization request..."
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
    if [ -n "$NOTARY_KEYCHAIN" ]; then
        NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN")
    fi
    xcrun notarytool submit "$NOTARY_ZIP" "${NOTARY_ARGS[@]}" --wait
    echo "Stapling notarization ticket..."
    xcrun stapler staple "$APP_DIR"
fi

echo "Verifying application bundle..."
plutil -lint "$CONTENTS_DIR/Info.plist"
if [ "$(plutil -extract CFBundleIdentifier raw "$CONTENTS_DIR/Info.plist")" != "$BUNDLE_ID" ]; then
    echo "Error: unexpected bundle identifier." >&2
    exit 1
fi
codesign --verify --deep --strict "$APP_DIR"
if ! otool -L "$MACOS_DIR/OpenFind" | grep -F '@rpath/Sparkle.framework/' >/dev/null; then
    echo "Error: OpenFind executable is not linked to embedded Sparkle.framework." >&2
    exit 1
fi
if ! otool -l "$MACOS_DIR/OpenFind" | grep -F '@executable_path/../Frameworks' >/dev/null; then
    echo "Error: executable is missing the application Frameworks rpath." >&2
    exit 1
fi
if [ ! -f "$RESOURCES_DIR/en.lproj/Localizable.strings" ] \
    || [ ! -f "$RESOURCES_DIR/zh-Hans.lproj/Localizable.strings" ]; then
    echo "Error: application localizations are missing from Contents/Resources." >&2
    exit 1
fi
if [ ! -f "$RESOURCES_DIR/OpenFind.sdef" ]; then
    echo "Error: AppleScript definition is missing from Contents/Resources." >&2
    exit 1
fi
if [ "$(plutil -extract NSAppleScriptEnabled raw "$CONTENTS_DIR/Info.plist")" != "true" ] \
    || [ "$(plutil -extract OSAScriptingDefinition raw "$CONTENTS_DIR/Info.plist")" != "OpenFind.sdef" ]; then
    echo "Error: AppleScript bundle metadata is invalid." >&2
    exit 1
fi
sdp -fh -o - "$RESOURCES_DIR/OpenFind.sdef" >/dev/null
for arch in $ARCHS; do
    lipo "$MACOS_DIR/OpenFind" -verify_arch "$arch"
done

echo "Running packaged executable smoke test..."
OPENFIND_CACHE_PATH="$BUILD_TMP/smoke-index.bin" \
    "$MACOS_DIR/OpenFind" \
    --search OpenFindPackagedSmokeNeedleZ7Q9 "$BUILD_TMP" --refresh \
    >/dev/null

if [ "$NOTARIZE" = "1" ]; then
    spctl --assess --type execute --verbose=4 "$APP_DIR"
elif [ "$DISTRIBUTION" = "customer" ]; then
    echo "Skipping Apple Gatekeeper assessment: the pinned self-signed customer build requires a first-launch override."
else
    echo "Skipping Gatekeeper assessment: set NOTARIZE=1 with Developer ID credentials for distributable validation."
fi

echo "Creating verified distribution archive..."
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE_TMP"
unzip -tq "$ARCHIVE_TMP" >/dev/null
VERIFY_DIR="$BUILD_TMP/archive-verification"
mkdir -p "$VERIFY_DIR"
: > "$VERIFY_DIR/.metadata_never_index"
ditto -x -k "$ARCHIVE_TMP" "$VERIFY_DIR"
VERIFY_APP="$VERIFY_DIR/$APP_NAME"
if [ ! -d "$VERIFY_APP" ]; then
    echo "Error: archive did not restore $APP_NAME." >&2
    exit 1
fi
if [ "$(plutil -extract CFBundleIdentifier raw "$VERIFY_APP/Contents/Info.plist" 2>/dev/null || true)" != "$BUNDLE_ID" ]; then
    echo "Error: archived app has the wrong bundle identifier." >&2
    exit 1
fi
codesign --verify --deep --strict "$VERIFY_APP"
if [ ! -f "$VERIFY_APP/Contents/Resources/OpenFind.sdef" ]; then
    echo "Error: archived app is missing its AppleScript definition." >&2
    exit 1
fi
for arch in $ARCHS; do
    lipo "$VERIFY_APP/Contents/MacOS/OpenFind" -verify_arch "$arch"
done

mv -f "$ARCHIVE_TMP" "$ARCHIVE_PATH"
unzip -tq "$ARCHIVE_PATH" >/dev/null
shasum -a 256 "$ARCHIVE_PATH" > "$CHECKSUM_TMP"
mv -f "$CHECKSUM_TMP" "$CHECKSUM_PATH"
if [ -d "$STALE_APP" ]; then
    echo "Error: raw app bundle remains in dist." >&2
    exit 1
fi

echo "OK: $ARCHIVE_PATH"
echo "OK: $CHECKSUM_PATH"
