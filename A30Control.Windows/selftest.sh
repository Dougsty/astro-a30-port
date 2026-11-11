#!/bin/sh
# Runs the A30Kit protocol selftest on this Mac (no headset needed).
set -e
cd "$(dirname "$0")"
. ./env.sh
rsync -a --delete --exclude dist --exclude bin --exclude obj ./ "$SNAP/"
dotnet run --project "$SNAP/A30Kit.SelfTest"
