#!/bin/sh
# Builds A30 Control and installs it to /Applications (a fixed location is needed for
# "Open at login"). Quits a running copy first, then launches the installed app.
set -e
cd "$(dirname "$0")"
./build.sh
pkill -x A30Control 2>/dev/null || true   # Dock-style quit is intercepted by the app, so kill it
sleep 1
rm -rf "/Applications/A30 Control.app"
cp -R "build/A30 Control.app" /Applications/
open "/Applications/A30 Control.app"
echo "Installed /Applications/A30 Control.app"
