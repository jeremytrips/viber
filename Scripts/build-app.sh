#!/bin/bash
# Builds dist/Viber.app: the app, the `viber` helper CLI, and the Claude Code plugin with Viber's skills.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.1.0"
BUILD="1"

swift build -c release --product Viber
swift build -c release --product viber-ctl
BIN="$(swift build -c release --show-bin-path)"

APP="dist/Viber.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"

cp "$BIN/Viber" "$APP/Contents/MacOS/Viber"
# The CLI lives in Resources/bin, not Contents/MacOS: "Viber" and "viber" collide on case-insensitive APFS.
cp "$BIN/viber-ctl" "$APP/Contents/Resources/bin/viber"
chmod +x "$APP/Contents/Resources/bin/viber"
cp -R plugin "$APP/Contents/Resources/plugin"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.jeremytrips.Viber</string>
<key>CFBundleName</key><string>Viber</string>
<key>CFBundleDisplayName</key><string>Viber</string>
<key>CFBundleExecutable</key><string>Viber</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${VERSION}</string>
<key>CFBundleVersion</key><string>${BUILD}</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Ad-hoc signing for local use: sign the nested helper first, then the bundle (no --deep).
# Distribution would need a Developer ID and notarization.
codesign --force --sign - "$APP/Contents/Resources/bin/viber"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP/Contents/Resources/bin/viber"
codesign --verify --strict "$APP"

echo "Built $(pwd)/$APP"
