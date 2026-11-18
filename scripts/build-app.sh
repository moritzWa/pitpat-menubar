#!/bin/bash
# Builds dist/PitPatBar.app (universal). Ad-hoc signed unless SIGN_IDENTITY is set.
#   scripts/build-app.sh [version]
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/build-app.sh 1.0.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(cat VERSION)}"
IDENTITY="${SIGN_IDENTITY:--}"
APP="dist/PitPatBar.app"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/PitPatBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/PitPatBar"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.moritzwa.pitpatbar</string>
  <key>CFBundleName</key><string>PitPat Bar</string>
  <key>CFBundleDisplayName</key><string>PitPat Bar</string>
  <key>CFBundleExecutable</key><string>PitPatBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>PitPat Bar talks to the walking pads over Bluetooth to start them and change their speed.</string>
</dict>
</plist>
PLIST

OPTIONS=()
[ "$IDENTITY" != "-" ] && OPTIONS=(--options runtime --timestamp)
codesign --force --sign "$IDENTITY" ${OPTIONS[@]+"${OPTIONS[@]}"} --entitlements scripts/PitPatBar.entitlements "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "Built $APP ($VERSION)"
