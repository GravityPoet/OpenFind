#!/bin/bash
set -euo pipefail

# Ensure working directory is correct
cd "$(dirname "$0")/.."

# Clean up dist folder
rm -rf dist
mkdir -p dist

# 1. Build release binary using SDK override
echo "Building Release executable..."
xcrun --sdk macosx swift build -c release

# Get binary path
BIN_PATH=$(xcrun --sdk macosx swift build -c release --show-bin-path)

# 2. Build icon using our script
echo "Generating application icon..."
swift Scripts/make_icon.swift

# 3. Assemble .app bundle structure
APP_DIR="dist/OpenFind.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# Copy binary
cp "$BIN_PATH/OpenFind" "$MACOS_DIR/OpenFind"

# Copy SPM Resource Bundle
echo "Copying localization bundle..."
BUNDLE_NAME="OpenFind_OpenFind.bundle"
if [ -d "$BIN_PATH/$BUNDLE_NAME" ]; then
    cp -R "$BIN_PATH/$BUNDLE_NAME" "$MACOS_DIR/"
else
    echo "Warning: $BUNDLE_NAME not found in $BIN_PATH directly, searching..."
    FIND_BUNDLE=$(find .build -name "$BUNDLE_NAME" -type d | head -n 1)
    if [ -n "$FIND_BUNDLE" ]; then
        cp -R "$FIND_BUNDLE" "$MACOS_DIR/"
    else
        echo "Error: Cannot find $BUNDLE_NAME"
        exit 1
    fi
fi

# Normalize localization directory casing. SwiftPM lowercases region subtags
# (zh-hans), but the BCP-47 canonical form is zh-Hans. Case-insensitive volumes
# tolerate the lowercase name; case-sensitive volumes/CI do not. Rename through a
# temp name so the case-only change also sticks on case-insensitive filesystems.
LPROJ_LOWER="$MACOS_DIR/$BUNDLE_NAME/zh-hans.lproj"
if [ -d "$LPROJ_LOWER" ]; then
    echo "Normalizing zh-hans.lproj -> zh-Hans.lproj..."
    mv "$LPROJ_LOWER" "$MACOS_DIR/$BUNDLE_NAME/zh-Hans.lproj.tmp"
    mv "$MACOS_DIR/$BUNDLE_NAME/zh-Hans.lproj.tmp" "$MACOS_DIR/$BUNDLE_NAME/zh-Hans.lproj"
fi

# Copy icon
mv OpenFind.icns "$RESOURCES_DIR/"

# Create PkgInfo
echo "APPL????" > "$CONTENTS_DIR/PkgInfo"

# Copy Info.plist
cp Info.plist "$CONTENTS_DIR/Info.plist"

# 4. Sign the app bundle ad-hoc
echo "Signing the application bundle..."
codesign --force --deep --sign - "$APP_DIR"

# 5. Verify build quality
echo "Verifying application bundle..."
plutil -lint "$CONTENTS_DIR/Info.plist"
codesign --verify --deep --strict "$APP_DIR"
test -x "$MACOS_DIR/OpenFind"

echo "OK: dist/OpenFind.app"
