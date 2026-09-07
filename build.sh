#!/bin/sh
# Builds the app bundle into build/
# --universal produces a binary for both architectures, which is what a release
# needs; without it the build is for this machine only and is much faster
set -e
cd "$(dirname "$0")"

APP="build/Clipboard History.app"

if [ "$1" = "--universal" ]; then
  swift build -c release --arch arm64 --arch x86_64
  BINARY=".build/apple/Products/Release/ClipHistory"
else
  swift build -c release
  BINARY=".build/release/ClipHistory"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/ClipHistory"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "built: $APP"
lipo -archs "$APP/Contents/MacOS/ClipHistory" | sed 's/^/arch:  /'
du -sh "$APP" | awk '{print "size:  "$1}'
