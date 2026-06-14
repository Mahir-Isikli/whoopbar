#!/usr/bin/env bash
# Auto-run the WHOOP collector every 30 min (so the trend charts stay fresh).
# Usage:  WHOOP_CLIENT_ID=... WHOOP_CLIENT_SECRET=... ./collector/schedule.sh
set -euo pipefail
: "${WHOOP_CLIENT_ID:?set WHOOP_CLIENT_ID}"
: "${WHOOP_CLIENT_SECRET:?set WHOOP_CLIENT_SECRET}"

cd "$(dirname "$0")/.."
REPO="$(pwd)"
LABEL="com.mahir.whoopcollector"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>/usr/bin/python3</string><string>$REPO/collector/whoop_collector.py</string></array>
    <key>RunAtLoad</key><true/>
    <key>StartInterval</key><integer>1800</integer>
    <key>StandardErrorPath</key><string>/tmp/whoopcollector.err.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>WHOOP_CLIENT_ID</key><string>$WHOOP_CLIENT_ID</string>
        <key>WHOOP_CLIENT_SECRET</key><string>$WHOOP_CLIENT_SECRET</string>
    </dict>
</dict>
</plist>
EOF

DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
for _ in $(seq 1 10); do launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break; sleep 0.5; done
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl kickstart -k "$DOMAIN/$LABEL"
echo "Scheduled: collector runs now and every 30 min. Trends will appear in WhoopBar."
