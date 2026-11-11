#!/bin/sh
# Builds dist/A30Control.exe (Windows x64, self-contained, single file) on this Mac.
set -e
cd "$(dirname "$0")"
. ./env.sh
./icons.sh
rsync -a --delete --exclude dist --exclude bin --exclude obj ./ "$SNAP/"
dotnet run --project "$SNAP/A30Kit.SelfTest"
dotnet publish "$SNAP/A30Control/A30Control.csproj" -c Release -r win-x64 --self-contained \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -o "$SNAP/../dist"
mkdir -p dist
cp "$SNAP/../dist/A30Control.exe" dist/
# Setup installer (NSIS: brew install makensis)
VERSION=$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' A30Control/A30Control.csproj)
makensis -V2 -DVERSION="$VERSION" installer/A30Control.nsi
ls -lh dist/
