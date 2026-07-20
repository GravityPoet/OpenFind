#!/bin/bash
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
    echo "Error: this installer requires macOS." >&2
    exit 2
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/Scripts/build_customer_app.sh"
APP_NAME="OpenFind.app"
ARCHIVE_PATH="$ROOT_DIR/dist/OpenFind.zip"
INSTALL_APP="/Applications/$APP_NAME"
BUNDLE_ID="com.openfind.app"
EXECUTABLE_NAME="OpenFind"
ARCHS="${ARCHS:-arm64 x86_64}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
PROCESS_PATTERN='^/Applications/OpenFind\.app/Contents/MacOS/OpenFind( |$)'
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/openfind-install.XXXXXX")"
SOURCE_APP="$TEMP_ROOT/$APP_NAME"
INSTALL_STAGING="/Applications/.openfind-staging-$$"
DISPLACED_APP="/Applications/.openfind-displaced-$$"
REPLACEMENT_STARTED=0
HAD_PREVIOUS=0
APPCAST_CACHE_ROOT="$HOME/Library/Caches/Sparkle_generate_appcast"

remove_known_tree() {
    local target="$1"
    case "$target" in
        "$TEMP_ROOT"|"$INSTALL_STAGING"|"$DISPLACED_APP"|"$INSTALL_APP") ;;
        *)
            echo "Error: refusing to remove unexpected install path: $target" >&2
            return 64
            ;;
    esac
    if [ -e "$target" ] || [ -L "$target" ]; then
        /bin/rm -R "$target"
    fi
}

remove_validated_appcast_bundle() {
    local cached_app="$1"
    case "$cached_app" in
        "$APPCAST_CACHE_ROOT"/*) ;;
        *)
            echo "Error: refusing to remove app outside the appcast cache: $cached_app" >&2
            return 64
            ;;
    esac
    if [ "$(basename "$cached_app")" != "$APP_NAME" ]; then
        echo "Error: refusing to remove an unexpected appcast cache entry: $cached_app" >&2
        return 64
    fi
    if [ -e "$cached_app" ] || [ -L "$cached_app" ]; then
        /bin/rm -R "$cached_app"
    fi
}

unregister_app_bundle() {
    app_bundle="$1"
    if [ -d "$app_bundle/Contents" ]; then
        while IFS= read -r -d '' nested_app; do
            "$LSREGISTER" -u "$nested_app" >/dev/null 2>&1 || true
        done < <(find "$app_bundle/Contents" -type d -name '*.app' -prune -print0 2>/dev/null)
    fi
    "$LSREGISTER" -u "$app_bundle" >/dev/null 2>&1 || true
}

cleanup_openfind_appcast_cache() {
    [ -d "$APPCAST_CACHE_ROOT" ] || return 0
    while IFS= read -r -d '' cached_app; do
        local cached_id
        cached_id="$(plutil -extract CFBundleIdentifier raw "$cached_app/Contents/Info.plist" 2>/dev/null || true)"
        [ "$cached_id" = "$BUNDLE_ID" ] || continue
        unregister_app_bundle "$cached_app"
        remove_validated_appcast_bundle "$cached_app"
    done < <(find "$APPCAST_CACHE_ROOT" -type d -name "$APP_NAME" -prune -print0 2>/dev/null)
}

cleanup_openfind_temp_bundles() {
    local temp_root="${TMPDIR:-/tmp}"
    [ -d "$temp_root" ] || return 0
    while IFS= read -r -d '' cached_app; do
        local cached_id
        cached_id="$(plutil -extract CFBundleIdentifier raw "$cached_app/Contents/Info.plist" 2>/dev/null || true)"
        [ "$cached_id" = "$BUNDLE_ID" ] || continue
        unregister_app_bundle "$cached_app"
        # Preserve the diagnostic bundle, but remove the .app suffix so
        # Spotlight and LaunchServices cannot present it as an installation.
        [ -e "$cached_app.disabled.$$" ] || mv "$cached_app" "$cached_app.disabled.$$"
    done < <(find "$temp_root" -type d -path '*/openfind-*/OpenFind.app' -prune -print0 2>/dev/null)
}

cleanup_or_rollback() {
    status=$?
    trap - EXIT INT TERM
    unregister_app_bundle "$SOURCE_APP"
    remove_known_tree "$TEMP_ROOT"
    remove_known_tree "$INSTALL_STAGING"
    if [ "$status" -ne 0 ] && [ "$REPLACEMENT_STARTED" -eq 1 ]; then
        unregister_app_bundle "$INSTALL_APP"
        remove_known_tree "$INSTALL_APP"
        restored=0
        if [ "$HAD_PREVIOUS" -eq 1 ] && [ -d "$DISPLACED_APP" ]; then
            mv "$DISPLACED_APP" "$INSTALL_APP"
            restored=1
        fi
        if [ "$restored" -eq 1 ]; then
            "$LSREGISTER" -f "$INSTALL_APP" >/dev/null 2>&1 || true
            open "$INSTALL_APP" >/dev/null 2>&1 || true
        elif [ "$HAD_PREVIOUS" -eq 1 ]; then
            echo "Error: failed to restore the previous OpenFind installation." >&2
        fi
    fi
    exit "$status"
}
trap cleanup_or_rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

: > "$TEMP_ROOT/.metadata_never_index"
remove_known_tree "$INSTALL_STAGING"
remove_known_tree "$DISPLACED_APP"
cleanup_openfind_appcast_cache
cleanup_openfind_temp_bundles

ARCHS="$ARCHS" "$BUILD_SCRIPT"
if [ ! -f "$ARCHIVE_PATH" ]; then
    echo "Error: build did not produce $ARCHIVE_PATH." >&2
    exit 1
fi
unzip -tq "$ARCHIVE_PATH" >/dev/null
ditto -x -k "$ARCHIVE_PATH" "$TEMP_ROOT"
if [ ! -d "$SOURCE_APP" ]; then
    echo "Error: archive did not restore $APP_NAME." >&2
    exit 1
fi
if [ "$(plutil -extract CFBundleIdentifier raw "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || true)" != "$BUNDLE_ID" ]; then
    echo "Error: archive contains the wrong application." >&2
    exit 1
fi
codesign --verify --deep --strict "$SOURCE_APP"
for arch in $ARCHS; do
    lipo "$SOURCE_APP/Contents/MacOS/$EXECUTABLE_NAME" -verify_arch "$arch"
done

if [ -d "$INSTALL_APP" ]; then
    HAD_PREVIOUS=1
fi

ditto --noextattr --noqtn "$SOURCE_APP" "$INSTALL_STAGING"
xattr -cr "$INSTALL_STAGING"
codesign --verify --deep --strict "$INSTALL_STAGING"

/usr/bin/swift -e '
  import AppKit
  for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.openfind.app") {
    _ = app.terminate()
  }
' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do
    if ! pgrep -f "$PROCESS_PATTERN" >/dev/null; then
        break
    fi
    sleep 1
done
if pgrep -f "$PROCESS_PATTERN" >/dev/null; then
    pkill -TERM -f "$PROCESS_PATTERN" || true
    sleep 1
fi
if pgrep -f "$PROCESS_PATTERN" >/dev/null; then
    echo "Error: OpenFind did not quit cleanly." >&2
    exit 1
fi

REPLACEMENT_STARTED=1
if [ "$HAD_PREVIOUS" -eq 1 ]; then
    "$LSREGISTER" -u "$INSTALL_APP" >/dev/null 2>&1 || true
    mv "$INSTALL_APP" "$DISPLACED_APP"
    unregister_app_bundle "$DISPLACED_APP"
fi
mv "$INSTALL_STAGING" "$INSTALL_APP"
xattr -cr "$INSTALL_APP"
codesign --verify --deep --strict "$INSTALL_APP"
if [ "$(plutil -extract CFBundleIdentifier raw "$INSTALL_APP/Contents/Info.plist")" != "$BUNDLE_ID" ]; then
    echo "Error: installed app has the wrong bundle identifier." >&2
    exit 1
fi
for arch in $ARCHS; do
    lipo "$INSTALL_APP/Contents/MacOS/$EXECUTABLE_NAME" -verify_arch "$arch"
done
"$LSREGISTER" -f "$INSTALL_APP" >/dev/null 2>&1 || true

open "$INSTALL_APP"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if pgrep -f "$PROCESS_PATTERN" >/dev/null; then
        break
    fi
    sleep 1
done
if ! pgrep -f "$PROCESS_PATTERN" >/dev/null; then
    echo "Error: OpenFind did not start from /Applications." >&2
    exit 1
fi

unregister_app_bundle "$DISPLACED_APP"
remove_known_tree "$DISPLACED_APP"
unregister_app_bundle "$SOURCE_APP"
remove_known_tree "$TEMP_ROOT"

physical_paths="$(
    for root in "/Applications" "$ROOT_DIR" "/private/tmp" "$HOME/Library/Application Support/Codex/Backups/OpenFind"; do
        [ -d "$root" ] || continue
        find "$root" -type d -name '*.app' -prune -print0 2>/dev/null
    done | while IFS= read -r -d '' app; do
        plist="$app/Contents/Info.plist"
        [ -f "$plist" ] || continue
        app_id="$(plutil -extract CFBundleIdentifier raw "$plist" 2>/dev/null || true)"
        if [ "$app_id" = "$BUNDLE_ID" ]; then
            printf '%s\n' "$app"
        fi
    done | sort -u
)"
if [ "$physical_paths" != "$INSTALL_APP" ]; then
    echo "Error: duplicate OpenFind app bundles remain on disk:" >&2
    printf '%s\n' "${physical_paths:-<none>}" >&2
    exit 1
fi

spotlight_paths=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
    spotlight_paths="$(mdfind 'kMDItemCFBundleIdentifier == "com.openfind.app"c' | sort -u)"
    [ "$spotlight_paths" = "$INSTALL_APP" ] && break
    sleep 1
done
if [ "$spotlight_paths" != "$INSTALL_APP" ]; then
    echo "Error: Spotlight still reports duplicate OpenFind apps:" >&2
    printf '%s\n' "${spotlight_paths:-<none>}" >&2
    exit 1
fi

launchservices_paths="$(
    FINAL_APP_BUNDLE_ID="$BUNDLE_ID" /usr/bin/swift -e '
      import Foundation
      import CoreServices
      let identifier = ProcessInfo.processInfo.environment["FINAL_APP_BUNDLE_ID"]! as CFString
      let urls = (LSCopyApplicationURLsForBundleIdentifier(identifier, nil)?.takeRetainedValue() as? [URL]) ?? []
      for url in urls.sorted(by: { $0.path < $1.path }) { print(url.path) }
    ' | sort -u
)"
if [ "$launchservices_paths" != "$INSTALL_APP" ]; then
    echo "Error: LaunchServices still reports duplicate OpenFind apps:" >&2
    printf '%s\n' "${launchservices_paths:-<none>}" >&2
    exit 1
fi

dock_paths="$(
    FINAL_APP_BUNDLE_ID="$BUNDLE_ID" /usr/bin/swift -e '
      import Foundation
      let bundleID = ProcessInfo.processInfo.environment["FINAL_APP_BUNDLE_ID"]!
      let plistURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/com.apple.dock.plist")
      guard let data = try? Data(contentsOf: plistURL),
            let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dictionary = root as? [String: Any],
            let apps = dictionary["persistent-apps"] as? [[String: Any]] else { exit(0) }
      for app in apps {
        guard let tile = app["tile-data"] as? [String: Any],
              tile["bundle-identifier"] as? String == bundleID,
              let file = tile["file-data"] as? [String: Any],
              let raw = file["_CFURLString"] as? String else { continue }
        if let url = URL(string: raw), url.isFileURL { print(url.path) } else { print(raw) }
      }
    ' | sort -u
)"
if [ -n "$dock_paths" ] && [ "$dock_paths" != "$INSTALL_APP" ]; then
    killall Dock >/dev/null 2>&1 || true
    sleep 2
    dock_paths="$(
        FINAL_APP_BUNDLE_ID="$BUNDLE_ID" /usr/bin/swift -e '
          import Foundation
          let bundleID = ProcessInfo.processInfo.environment["FINAL_APP_BUNDLE_ID"]!
          let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.dock.plist")
          guard let data = try? Data(contentsOf: plistURL),
                let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
                let dictionary = root as? [String: Any],
                let apps = dictionary["persistent-apps"] as? [[String: Any]] else { exit(0) }
          for app in apps {
            guard let tile = app["tile-data"] as? [String: Any],
                  tile["bundle-identifier"] as? String == bundleID,
                  let file = tile["file-data"] as? [String: Any],
                  let raw = file["_CFURLString"] as? String else { continue }
            if let url = URL(string: raw), url.isFileURL { print(url.path) } else { print(raw) }
          }
        ' | sort -u
    )"
fi
if [ -n "$dock_paths" ] && [ "$dock_paths" != "$INSTALL_APP" ]; then
    echo "Error: Dock still points OpenFind at a non-canonical path:" >&2
    printf '%s\n' "$dock_paths" >&2
    exit 1
fi

unregister_app_bundle "$DISPLACED_APP"
remove_known_tree "$DISPLACED_APP"
REPLACEMENT_STARTED=0
trap - EXIT INT TERM
printf 'INSTALLED_APP=%s\n' "$INSTALL_APP"
printf 'ARCHIVE=%s\n' "$ARCHIVE_PATH"
