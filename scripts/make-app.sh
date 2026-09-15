#!/usr/bin/env bash
#
# Wraps the agentprobe executable in a minimal .app bundle.
#
# Why: GameController wireless discovery, Bluetooth usage and stable TCC
# (Accessibility / Input Monitoring) grants all behave better for a bundled,
# signed app than for a bare binary launched from a shell.
#
# Usage: scripts/make-app.sh [debug|release]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
APP="$ROOT/.build/PocketAgentProbe.app"

swift build -c "$CONFIG" --product agentprobe
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/agentprobe" "$APP/Contents/MacOS/agentprobe"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>agentprobe</string>
	<key>CFBundleIdentifier</key>
	<string>com.pocketagentremote.probe</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>PocketAgentProbe</string>
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
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>PocketAgentProbe reads input from a paired Bluetooth game controller so the controller mapping can be verified.</string>
	<key>NSHumanReadableCopyright</key>
	<string>Phase 0 hardware probe — PocketAgentRemote</string>
</dict>
</plist>
PLIST

if ! codesign --force --sign - "$APP" 2>/dev/null; then
	echo "warning: ad-hoc codesign failed; TCC grants may not persist across rebuilds" >&2
fi

echo "built: $APP"
echo "run:   \"$APP/Contents/MacOS/agentprobe\" watch --log logs/probe.jsonl"
