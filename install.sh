#!/usr/bin/env bash
# Build WhoopBar and install it as a login item (auto-starts, restarts on login).
set -euo pipefail
cd "$(dirname "$0")"
APP_DIR="$(pwd)"

./build.sh

PLIST="$HOME/Library/LaunchAgents/com.mahir.whoopbar.plist"
SYNC_BLOCK=""
if [ -n "${WHOOPBAR_SYNC:-}" ]; then
  SYNC_BLOCK="
    <key>EnvironmentVariables</key>
    <dict><key>WHOOPBAR_SYNC</key><string>${WHOOPBAR_SYNC}</string></dict>"
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.mahir.whoopbar</string>
    <key>ProgramArguments</key>
    <array><string>${APP_DIR}/WhoopBar.app/Contents/MacOS/WhoopBar</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict><key>SuccessfulExit</key><false/></dict>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardErrorPath</key><string>/tmp/whoopbar.err.log</string>
    <key>StandardOutPath</key><string>/tmp/whoopbar.out.log</string>${SYNC_BLOCK}
</dict>
</plist>
EOF

# Modern launchctl API (legacy load/unload are no-ops on recent macOS).
DOMAIN="gui/$(id -u)"
LABEL="com.mahir.whoopbar"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
for _ in $(seq 1 10); do launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break; sleep 0.5; done
pkill -f "MacOS/WhoopBar" 2>/dev/null || true; sleep 1
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl kickstart -k "$DOMAIN/$LABEL"
echo "Installed. Look for the heart in your menu bar and allow Bluetooth when asked."
