#!/bin/bash
# Builds build/Switchel.app (release, arm64, ad-hoc signed) and build/Switchel.zip for GitHub releases.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
bin="$(swift build -c release --arch arm64 --show-bin-path)"

app=build/Switchel.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Switchel" "$app/Contents/MacOS/"
cp Resources/Info.plist "$app/Contents/"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
codesign --force --sign - "$app"

rm -f build/Switchel.zip
ditto -c -k --keepParent "$app" build/Switchel.zip

echo "Built $app and build/Switchel.zip"
