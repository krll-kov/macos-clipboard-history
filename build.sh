#!/bin/sh
# Builds the app bundle into build/
# --universal builds both architectures, which is what a release needs; without
# it the build is for this machine only and is much faster
set -e
cd "$(dirname "$0")"

APP="build/Clipboard History.app"
BINARY=".build/release/ClipHistory"

if [ "$1" = "--universal" ]; then
  # One build per architecture joined with lipo, rather than swift build --arch:
  # that flag switches to the Xcode build system, which does not carry
  # swiftLanguageMode over from the manifest and fails with an empty
  # SWIFT_VERSION
  swift build -c release --triple arm64-apple-macosx
  swift build -c release --triple x86_64-apple-macosx
  mkdir -p .build/universal
  BINARY=".build/universal/ClipHistory"
  lipo -create \
    .build/arm64-apple-macosx/release/ClipHistory \
    .build/x86_64-apple-macosx/release/ClipHistory \
    -output "$BINARY"
else
  swift build -c release
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/ClipHistory"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "built: $APP"
lipo -archs "$APP/Contents/MacOS/ClipHistory" | sed 's/^/arch:  /'
du -sh "$APP" | awk '{print "size:  "$1}'
