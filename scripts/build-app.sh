#!/usr/bin/env bash
# Build TFA.app (a double-clickable macOS bundle) from the SwiftPM executable.
#
# Usage:  scripts/build-app.sh [debug|release]   (default: release)
# Output: ./TFA.app
#
# The SwiftPM target/binary is still named "Mux" (so Package.swift keeps working); only the
# user-facing app bundle is "TFA" (Terminal For AI). Hence the two separate names below:
# BIN_NAME locates the built binary, APP_NAME names the bundle.
#
# For day-to-day development you can just run `swift run Mux` instead — this script is for
# producing a proper .app bundle (Info.plist + app icon + SwiftTerm resource bundle) that
# launches as a normal windowed app and can be moved to /Applications.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BIN_NAME="Mux"        # SwiftPM executable target (built binary name) — keep as "Mux"
APP_NAME="TFA"        # user-facing app/bundle name
BUNDLE_ID="com.tfa.app"
VERSION="0.7.0"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$BIN_NAME"
if [[ ! -x "$BIN" ]]; then
  echo "error: built executable not found at $BIN" >&2
  exit 1
fi

APP="$ROOT/$APP_NAME.app"
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Bundle executable is named after the app (CFBundleExecutable=TFA), copied from the Mux binary.
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# App icon: build AppIcon.icns from Icon.png (repo root) into Resources, if present. The standard
# macOS iconset needs 16/32/128/256/512 at @1x and @2x; sips downscales the single source PNG to
# each, then iconutil packs them. CFBundleIconFile is added to Info.plist only when the icns exists.
ICON_SRC="$ROOT/Icon.png"
ICON_PLIST=""
if [[ -f "$ICON_SRC" ]]; then
  echo "==> generating AppIcon.icns from Icon.png"
  ICONSET_DIR="$(mktemp -d)"
  ICONSET="$ICONSET_DIR/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s"             "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}.png"    >/dev/null
    sips -z "$((s*2))" "$((s*2))" "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET_DIR"
  ICON_PLIST=$'\n    <key>CFBundleIconFile</key>          <string>AppIcon</string>'
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>        <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>         <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>         <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>            <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>     <string>14.0</string>
    <key>NSHighResolutionCapable</key>    <true/>${ICON_PLIST}
    <key>NSPrincipalClass</key>           <string>NSApplication</string>
</dict>
</plist>
PLIST

# SwiftPM resource bundles (SwiftTerm ships a Metal shader bundle). In a .app, Bundle.module
# resolves these from Contents/Resources (= Bundle.main.resourceURL). Do NOT place them in
# Contents/MacOS — a nested .bundle there breaks `codesign`'s app-bundle format.
shopt -s nullglob
for b in "$BIN_DIR"/*.bundle; do
  cp -R "$b" "$APP/Contents/Resources/"
done
shopt -u nullglob

echo "==> done: $APP"
echo "    run with: open \"$APP\"   (or move it to /Applications)"
