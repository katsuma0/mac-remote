#!/bin/bash
# Stops and removes the MacRemoteServer LaunchAgent.
set -uo pipefail
LABEL="com.macremote.server"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -f "$HOME/Library/Application Support/MacRemote/MacRemoteServer"
echo "Removed. (Paired iPhones are kept in ~/Library/Application Support/Couchpad/pairings.json)"
