#!/bin/sh
# Builds build/A30Probe.app (A30Kit + Probe) and runs it via `open` so TCC accepts Bluetooth.
# Usage: ./probe.sh [--writes]
set -e
cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 5 -parse-as-library -O -o build/A30Probe Sources/A30Kit/*.swift Probe/main.swift -framework IOBluetooth
APP=build/A30Probe.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp build/A30Probe "$APP/Contents/MacOS/A30Probe"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.a30control.probe</string>
<key>CFBundleExecutable</key><string>A30Probe</string>
<key>CFBundleName</key><string>A30Probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>Talk to the ASTRO A30 control channel.</string>
</dict></plist>
EOF
xattr -cr "$APP"
codesign -s - -f "$APP"
rm -f build/probe.log
open -W -n --stdout "$PWD/build/probe.log" --stderr "$PWD/build/probe.log" "$APP" --args "$@"
cat build/probe.log
