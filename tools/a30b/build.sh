#!/bin/sh
# Builds a30b.app. Must be launched via `open` (see run.sh) so the app, not the
# parent terminal/IDE, is the TCC "responsible process" for Bluetooth access.
set -e
cd "$(dirname "$0")"
swiftc -o a30b a30b.swift -framework IOBluetooth
rm -rf a30b.app && mkdir -p a30b.app/Contents/MacOS
cp a30b a30b.app/Contents/MacOS/a30b
cp Info.plist a30b.app/Contents/Info.plist
xattr -cr a30b.app
codesign -s - -f a30b.app
