#!/bin/bash
# Stops and removes the MacRemoteServer LaunchAgent.
set -uo pipefail
LABEL="com.macremote.server"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -f "$HOME/Library/Application Support/MacRemote/MacRemoteServer"
echo "Removed. (Your PIN is kept in ~/Library/Application Support/MacRemote/pin.txt)"
