#!/bin/sh
# App icon, tray image and header logo from Doug's artwork, via the Mac app's prepicon tool.
set -e
cd "$(dirname "$0")"
C="$HOME/Library/Caches/A30Control.Windows/icons"
mkdir -p "$C" A30Control/Assets
cp ../A30Control/Tools/prepicon.swift ../A30Control/Assets/icon.png "$C/"   # snapshot outside iCloud
swiftc -O -o "$C/prepicon" "$C/prepicon.swift"
"$C/prepicon" "$C/icon.png" "$C"
for s in 16 24 32 48 256; do sips -z $s $s "$C/icon-1024.png" --out "$C/i$s.png" >/dev/null; done
python3 Tools/mkico.py A30Control/Assets/app.ico "$C/i16.png" "$C/i24.png" "$C/i32.png" "$C/i48.png" "$C/i256.png"
cp "$C/i32.png" A30Control/Assets/tray.png
cp "$C/logo.png" A30Control/Assets/logo.png
