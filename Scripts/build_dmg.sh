#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
ARCHIVE="$ROOT_DIR/dist/OpenFind.zip"
DMG="$ROOT_DIR/dist/OpenFind.dmg"
DMG_TMP="$ROOT_DIR/dist/.OpenFind.$$.dmg"
CHECKSUM_TMP="$ROOT_DIR/dist/.OpenFind.dmg.sha256.$$"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/openfind-dmg.XXXXXX")"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# Both packages are reproducible build artifacts; stage and verify the new
# image before replacing the previous DMG. No user data is changed.
cleanup() {
    dmg_exit_code=$?
    trap - EXIT INT TERM
    if [ -d "$STAGE/OpenFind.app" ]; then
        "$LSREGISTER" -u "$STAGE/OpenFind.app" >/dev/null 2>&1 || true
    fi
    case "$STAGE" in
        */openfind-dmg.*) /bin/rm -R "$STAGE" ;;
        *) echo "Error: unexpected DMG staging path." >&2; dmg_exit_code=64 ;;
    esac
    /bin/rm -f "$DMG_TMP" "$CHECKSUM_TMP"
    exit "$dmg_exit_code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

: > "$STAGE/.metadata_never_index"
test -f "$ARCHIVE"
unzip -tq "$ARCHIVE" >/dev/null
ditto -x -k "$ARCHIVE" "$STAGE"
APP="$STAGE/OpenFind.app"
test -d "$APP"
test "$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")" = "com.openfind.app"
codesign --verify --deep --strict "$APP"
for arch in ${ARCHS:-arm64 x86_64}; do
    lipo "$APP/Contents/MacOS/OpenFind" -verify_arch "$arch"
done
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "OpenFind $VERSION" -srcfolder "$STAGE" -ov \
    -format UDZO -imagekey zlib-level=9 "$DMG_TMP"
hdiutil verify "$DMG_TMP"
DMG_HASH="$(shasum -a 256 "$DMG_TMP" | awk '{print $1}')"
printf '%s  OpenFind.dmg\n' "$DMG_HASH" > "$CHECKSUM_TMP"
mv -f "$DMG_TMP" "$DMG"
mv -f "$CHECKSUM_TMP" "$DMG.sha256"
(cd dist && shasum -a 256 -c OpenFind.dmg.sha256)
echo "OK: $DMG"
