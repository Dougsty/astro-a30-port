#!/bin/sh
# Compiles the pure A30Kit sources with the tests and runs them. No headset needed.
set -e
cd "$(dirname "$0")"
mkdir -p build
# Snapshot outside iCloud Drive (see build.sh).
SRC=$(mktemp -d)
trap 'rm -rf "$SRC"' EXIT
cp Sources/A30Kit/Framing.swift Sources/A30Kit/IAP2Session.swift Sources/A30Kit/Codecs.swift Tests/*.swift "$SRC/"
swiftc -swift-version 5 -parse-as-library -o build/selftest "$SRC"/*.swift
build/selftest
