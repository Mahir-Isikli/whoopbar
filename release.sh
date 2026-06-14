#!/usr/bin/env bash
# Build a distributable WhoopBar.app (universal when possible) and zip it.
set -euo pipefail
cd "$(dirname "$0")"

APP="WhoopBar.app"; BIN="$APP/Contents/MacOS/WhoopBar"
rm -rf "$APP" build-arm64 build-x86_64
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

COMMON=(-swift-version 5 -O -framework SwiftUI -framework AppKit -framework CoreBluetooth -framework Charts -lsqlite3)

echo "compiling arm64..."
swiftc -target arm64-apple-macos14.0 "${COMMON[@]}" Sources/*.swift -o build-arm64
if echo "compiling x86_64..." && swiftc -target x86_64-apple-macos14.0 "${COMMON[@]}" Sources/*.swift -o build-x86_64 2>/tmp/whoopbar-x86.log; then
    lipo -create build-arm64 build-x86_64 -output "$BIN"
    echo "universal binary (arm64 + x86_64)"
else
    echo "x86_64 build failed (see /tmp/whoopbar-x86.log); shipping arm64-only"
    cp build-arm64 "$BIN"
fi
rm -f build-arm64 build-x86_64

codesign --force --sign - --identifier com.mahir.whoopbar "$APP"

VER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 1.0)"
ZIP="WhoopBar-$VER.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "built $ZIP"
lipo -archs "$BIN" 2>/dev/null || true
