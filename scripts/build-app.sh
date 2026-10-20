#!/usr/bin/env bash
# Builds dist/AgentWatch.app from the SwiftPM executable.
# Usage: scripts/build-app.sh [version]
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
APP="dist/AgentWatch.app"

swift build -c release --product AgentWatchApp
BIN="$(swift build -c release --product AgentWatchApp --show-bin-path)/AgentWatchApp"

ICON="Resources/AppIcon.icns"
[ -f "$ICON" ] || { echo "Missing $ICON: run 'swift scripts/make-icon.swift'" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AgentWatch"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Agent Watch</string>
    <key>CFBundleDisplayName</key><string>Agent Watch</string>
    <key>CFBundleIdentifier</key><string>dev.agentwatch.app</string>
    <key>CFBundleExecutable</key><string>AgentWatch</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Ad-hoc signature: enough to run locally and to register as a login item.
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

echo "Built $APP (version $VERSION)"
