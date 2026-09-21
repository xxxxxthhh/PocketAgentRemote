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
# SwiftPM nests its own sandbox, which some environments (and this project's own sandboxed
# sessions) refuse. POCKETAGENT_SWIFTPM_FLAGS lets a caller pass e.g. --disable-sandbox without
# changing the default behaviour for everyone else.
swift build -c "$CONFIG" --product pocketagent ${POCKETAGENT_SWIFTPM_FLAGS:-}
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path ${POCKETAGENT_SWIFTPM_FLAGS:-})"

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
	<!-- Required for "focus the other agent" (holding B): switching the frontmost application is a
	     system effect, and on macOS 14+ the only mechanism that actually works is an AppleScript
	     `activate`. Without this key the Apple Events request is refused outright instead of
	     prompting, and the feature silently does nothing. -->
	<key>NSAppleEventsUsageDescription</key>
	<string>PocketAgentRemote brings the Codex or Claude window to the front when you press the switch-agent button on the controller.</string>
</dict>
</plist>
PLIST

# Signing identity matters for more than validation here.
#
# An **ad-hoc** signature ("-") changes its cdhash on every build, and macOS records Accessibility
# grants against that hash — so every rebuild silently revokes the grant and the user has to
# re-approve it in System Settings. Measured on 2026-09-16: three rebuilds, three re-grants.
#
# Signing with a real certificate makes the designated requirement
# "identifier … and certificate leaf[subject.CN] = …", which is stable across rebuilds, so the grant
# survives. We look for an Apple Development identity first and fall back to ad-hoc with a warning.
IDENTITY="${POCKETAGENT_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
	IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
		| awk -F'"' '/Apple Development/ {print $2; exit}')"
fi

if [ -n "$IDENTITY" ]; then
	echo "signing with: $IDENTITY"
	echo "  (stable identity — Accessibility grants survive rebuilds)"
	if ! codesign --force --deep --sign "$IDENTITY" "$APP" 2>/dev/null; then
		echo "warning: signing with '$IDENTITY' failed; falling back to ad-hoc" >&2
		codesign --force --deep --sign - "$APP" 2>/dev/null || true
	fi
else
	echo "warning: no code-signing identity found — falling back to ad-hoc." >&2
	echo "         Accessibility must be re-approved after EVERY rebuild." >&2
	echo "         Fix: create an 'Apple Development' certificate in Xcode, or set" >&2
	echo "              POCKETAGENT_SIGN_IDENTITY=<identity>." >&2
	codesign --force --deep --sign - "$APP" 2>/dev/null || true
fi

# Install a copy where it can live permanently. The login item (Launch at Login) records the
# app's path, and build/ is wiped and recreated on every build — so the copy the user actually runs
# and registers is the one in /Applications. build/ stays as the intermediate product.
INSTALL="${POCKETAGENT_INSTALL_DIR:-/Applications}/PocketAgentRemote.app"
if ditto "$APP" "$INSTALL" 2>/dev/null; then
	echo "installed: $INSTALL"
else
	echo "warning: could not copy to $INSTALL — run from build/ instead" >&2
	INSTALL="$APP"
fi

echo
echo "built:  $APP"
echo "launch: open \"$INSTALL\""
echo
echo "First run:"
echo "  1. click the controller icon in the menu bar"
echo "  2. 'Request Accessibility Permission', then enable PocketAgentRemote in System Settings"
echo "  3. pick Profile → Codex (or Claude Code)"
