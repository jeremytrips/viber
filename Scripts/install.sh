#!/bin/bash
# Builds Viber.app and installs it into /Applications, replacing any previous copy.
set -euo pipefail
cd "$(dirname "$0")/.."

if pgrep -x Viber >/dev/null; then
    echo "Viber is running. Quit it first, then run this again." >&2
    exit 1
fi

Scripts/build-app.sh

DEST="/Applications/Viber.app"
rm -rf "$DEST"
ditto "dist/Viber.app" "$DEST"
echo "Installed $DEST"
