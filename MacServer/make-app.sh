#!/bin/bash
# Builds "Mac Remote.app" and installs it in /Applications (or ~/Applications).
# After this you can open Mac Remote from Launchpad, Spotlight or the Dock like any other app.
set -euo pipefail
cd "$(dirname "$0")"

echo "🔨 Building…"
swift build -c release
BIN=".build/release/MacRemoteServer"

APP="build/Mac Remote.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacRemote"

# App icon (drawn by the app itself, then converted to .icns)
ICON_TMP="$(mktemp -d)"
ICON_KEY=""
if "$BIN" --export-icon "$ICON_TMP/icon.png" >/dev/null 2>&1; then
    ICONSET="$ICON_TMP/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size "$ICON_TMP/icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z $double $double "$ICON_TMP/icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    if iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
        ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
    fi
fi
rm -rf "$ICON_TMP"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Mac Remote</string>
    <key>CFBundleDisplayName</key><string>Mac Remote</string>
    <key>CFBundleIdentifier</key><string>com.macremote.mac</string>
    <key>CFBundleExecutable</key><string>MacRemote</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>Mac Remote lets your iPhone find and control this Mac over your local network.</string>
    <key>NSBonjourServices</key><array><string>_macremote._tcp</string></array>
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
DEST="$DEST_DIR/Mac Remote.app"
if pgrep -x MacRemote >/dev/null; then
    osascript -e 'tell application id "com.macremote.mac" to quit' >/dev/null 2>&1 || true
    sleep 1
fi
rm -rf "$DEST"
ditto "$APP" "$DEST"

echo
echo "✅ Installed: $DEST"
echo "   Opening it now. Next time, open it from Launchpad, Spotlight (⌘ Space → Mac Remote) or the Dock."
echo
echo "   The first time, macOS asks for Accessibility permission for “Mac Remote”:"
echo "   System Settings → Privacy & Security → Accessibility → turn on Mac Remote."
open "$DEST"
