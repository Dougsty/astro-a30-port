#!/bin/sh
# Builds "build/A30 Control.app". Launch it with:  open "build/A30 Control.app"
# (Running the binary directly crashes: TCC needs the bundle's Bluetooth usage string.)
set -e
cd "$(dirname "$0")"
mkdir -p build
# iCloud Drive can touch files mid-compile ("input file was modified during the build"),
# so compile a snapshot of the sources from a temp dir.
SRC=$(mktemp -d)
trap 'rm -rf "$SRC"' EXIT
cp -R Sources Tools "$SRC/"
swiftc -swift-version 5 -parse-as-library -O -o build/A30Control \
  "$SRC"/Sources/A30Kit/*.swift "$SRC"/Sources/A30App/*.swift "$SRC"/Sources/A30App/Views/*.swift \
  -framework IOBluetooth
APP="build/A30 Control.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp build/A30Control "$APP/Contents/MacOS/A30Control"
cp Info.plist "$APP/Contents/Info.plist"
# App icon + menu bar glyph, both generated from Assets/icon.png.
swiftc -O -o build/prepicon "$SRC/Tools/prepicon.swift"
rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset "$APP/Contents/Resources"
build/prepicon Assets/icon.png build
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
cp build/menubar.png build/menubar@2x.png build/logo.png "$APP/Contents/Resources/"
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
# The project lives in iCloud Drive: Finder/iCloud can re-tag the bundle mid-build, which makes
# codesign fail with "resource fork, Finder information, or similar detritus". Clean and retry once.
xattr -cr "$APP"
codesign -s - -f "$APP" 2>/dev/null || { sleep 1; xattr -cr "$APP"; codesign -s - -f "$APP"; }
echo "Built $APP — run: open \"$PWD/$APP\""
