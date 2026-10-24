#!/bin/bash
# Downloads the scrcpy server Viber runs on Android devices for the live screen and input, into .build/scrcpy/,
# and checks it against the pinned SHA-256. Prints the path. Keep VERSION in step with Scrcpy.version (ViberCore).
# scrcpy is Apache-2.0: https://github.com/Genymobile/scrcpy (ThirdParty/scrcpy/LICENSE).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="5.0.1"
SHA256="764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536"
DIR=".build/scrcpy"
FILE="$DIR/scrcpy-server-v$VERSION"

matches() { [ -f "$1" ] && [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$SHA256" ]; }

if ! matches "$FILE"; then
    mkdir -p "$DIR"
    curl -fsSL --retry 2 -o "$FILE.download" "https://github.com/Genymobile/scrcpy/releases/download/v$VERSION/scrcpy-server-v$VERSION"
    if ! matches "$FILE.download"; then
        rm -f "$FILE.download"
        echo "scrcpy-server-v$VERSION does not match its pinned SHA-256" >&2
        exit 1
    fi
    mv "$FILE.download" "$FILE"
fi
echo "$(pwd)/$FILE"
