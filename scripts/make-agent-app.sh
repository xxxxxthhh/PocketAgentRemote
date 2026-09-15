#!/usr/bin/env bash
#
# Builds PocketAgentRemote.app — the menu bar app.
#
# A signed .app bundle (rather than a bare binary) is required for two reasons:
#   1. macOS remembers Accessibility / Input Monitoring grants per signed bundle. A bare binary
#      from a shell loses its grant every time it is rebuilt.
#   2. LSUIElement keeps it out of the Dock, which is what a menu bar utility wants.
#
# Usage: scripts/make-agent-app.sh [debug|release]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
APP="$ROOT/build/PocketAgentRemote.app"
BUNDLE_ID="com.pocketagentremote.app"

echo "building pocketagent ($CONFIG) …"
swift build -c "$CONFIG" --product pocketagent
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/pocketagent" "$APP/Contents/MacOS/PocketAgentRemote"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>PocketAgentRemote</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>PocketAgentRemote</string>
	<key>CFBundleDisplayName</key>
	<string>PocketAgentRemote</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>PocketAgentRemote — IINE L1162 remote for Codex / Claude desktop apps</string>
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>PocketAgentRemote reads input from a paired Bluetooth controller so it can drive Codex or Claude.</string>
</dict>
</plist>
PLIST

if ! codesign --force --deep --sign - "$APP" 2>/dev/null; then
	echo "warning: ad-hoc codesign failed; Accessibility grants may not persist across rebuilds" >&2
fi

echo
echo "built:  $APP"
echo "launch: open \"$APP\""
echo
echo "First run:"
echo "  1. click the controller icon in the menu bar"
echo "  2. 'Request Accessibility Permission', then enable PocketAgentRemote in System Settings"
echo "  3. pick Profile → Codex (or Claude Code)"
