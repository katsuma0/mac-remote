#!/bin/bash
# Builds a development copy of "Couchpad.app" (not sandboxed, with the brightness slider)
# and installs it in /Applications (or ~/Applications).
# For the Mac App Store version, use Couchpad.xcodeproj instead (see AppStore/SUBMITTING.md).
set -euo pipefail
cd "$(dirname "$0")"

echo "🔨 Building…"
swift build -c release
BIN=".build/release/MacRemoteServer"

APP="build/Couchpad.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Couchpad"

# App icon from the asset catalog (the PNGs are already named the way iconutil expects)
ICON_TMP="$(mktemp -d)"
ICON_KEY=""
mkdir -p "$ICON_TMP/AppIcon.iconset"
cp Resources/Assets.xcassets/AppIcon.appiconset/icon_*.png "$ICON_TMP/AppIcon.iconset/"
if iconutil -c icns "$ICON_TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
    ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi
rm -rf "$ICON_TMP"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Couchpad</string>
    <key>CFBundleDisplayName</key><string>Couchpad</string>
    <key>CFBundleIdentifier</key><string>app.couchpad.dev</string>
    <key>CFBundleExecutable</key><string>Couchpad</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>Couchpad lets your paired iPhone find and control this Mac over your local network.</string>
    <key>NSBonjourServices</key><array><string>_couchpad._tcp</string></array>
    $ICON_KEY
</dict>
</plist>
PLIST

# Sign it. With your Apple Development certificate (created when you ran the iPhone app from Xcode)
# macOS remembers the Accessibility permission across rebuilds; otherwise it's signed ad hoc and
# you may need to re-enable Accessibility after each rebuild.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/' || true)"
if [ -n "$IDENTITY" ]; then
    echo "🔏 Signing with: $IDENTITY"
    codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP"
else
    echo "🔏 Signing ad hoc"
    codesign --force --sign - "$APP"
fi

# Install
DEST_DIR="/Applications"
if [ ! -w "$DEST_DIR" ]; then
    DEST_DIR="$HOME/Applications"
    mkdir -p "$DEST_DIR"
fi
DEST="$DEST_DIR/Couchpad.app"
if pgrep -x Couchpad >/dev/null; then
    osascript -e 'tell application id "app.couchpad.dev" to quit' >/dev/null 2>&1 || true
    sleep 1
fi
rm -rf "$DEST"
ditto "$APP" "$DEST"

echo
echo "✅ Installed: $DEST"
echo "   Opening it now. Next time, open it from Launchpad, Spotlight (⌘ Space → Couchpad) or the Dock."
echo
echo "   The first time, macOS asks for Accessibility permission for “Couchpad”:"
echo "   System Settings → Privacy & Security → Accessibility → turn on Couchpad."
open "$DEST"
