#!/usr/bin/env bash
# Build WhoopBar.app — a SwiftUI menu bar app (LSUIElement) with CoreBluetooth + Charts.
set -euo pipefail
cd "$(dirname "$0")"

APP="WhoopBar.app"
BIN="$APP/Contents/MacOS/WhoopBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

echo "compiling…"
swiftc -swift-version 5 -target arm64-apple-macos14.0 \
    -framework SwiftUI -framework AppKit -framework CoreBluetooth -framework Charts \
    -lsqlite3 \
    Sources/*.swift -o "$BIN"

# Ad-hoc sign so the Bluetooth TCC permission sticks to a stable identity.
codesign --force --sign - --identifier com.mahir.whoopbar "$APP"

echo "built $APP"
