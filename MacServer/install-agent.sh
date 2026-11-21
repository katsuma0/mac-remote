#!/bin/bash
# Builds MacRemoteServer and installs it as a LaunchAgent so it starts
# automatically every time you log in (no Terminal window needed).
set -euo pipefail
cd "$(dirname "$0")"

echo "Building…"
swift build -c release

DEST="$HOME/Library/Application Support/MacRemote"
BIN="$DEST/MacRemoteServer"
PLIST="$HOME/Library/LaunchAgents/com.macremote.server.plist"
LABEL="com.macremote.server"

mkdir -p "$DEST" "$HOME/Library/LaunchAgents"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
cp .build/release/MacRemoteServer "$BIN"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$BIN</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$DEST/server.log</string>
    <key>StandardErrorPath</key><string>$DEST/server.log</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo
echo "✅ Installed. MacRemoteServer now runs in the background and starts at login."
sleep 2
CODE="$(grep -oE '^ +[0-9]{3} [0-9]{3}$' "$DEST/server.log" | tail -1 | tr -d ' ')"
if [ -n "$CODE" ]; then
    echo "🔗 Pairing is open for 3 minutes. On your iPhone, pick this Mac and enter: $CODE"
else
    echo "🔗 To pair another iPhone later, use the Couchpad app (Pair iPhone…), or run:"
    echo "   ./uninstall-agent.sh && swift run -c release MacRemoteServer --pair"
fi
echo
echo "IMPORTANT: macOS will ask for Accessibility permission for 'MacRemoteServer'."
echo "Tip: the Couchpad app (./make-app.sh) is easier – it has a window, a menu bar icon and pairing."
echo "  System Settings → Privacy & Security → Accessibility → turn on MacRemoteServer."
echo "  (If it's already listed from an older build, remove it with '−' and run this script again.)"
echo "Log file: $DEST/server.log"
