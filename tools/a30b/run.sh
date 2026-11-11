#!/bin/sh
# Usage: ./run.sh [--sdp] [addr]   — output also saved to a30b.log
cd "$(dirname "$0")"
rm -f a30b.log
open -W -n --stdout "$PWD/a30b.log" --stderr "$PWD/a30b.log" a30b.app --args "$@"
cat a30b.log
