#!/bin/sh
set -e
cd "$(dirname "$0")"

APP="build/Clipboard History.app"
swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ClipHistory "$APP/Contents/MacOS/ClipHistory"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "built: $APP"
du -sh "$APP" | awk '{print "size:  "$1}'
