#!/usr/bin/env bash
# Builds the app, installs it to ~/Applications, and starts it at every login.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

DEST="$HOME/Applications/ClaudeUsage.app"
LABEL="local.claude-usage-widget"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

pkill -x ClaudeUsage 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$DEST"
cp -R build/ClaudeUsage.app "$DEST"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$DEST/Contents/MacOS/ClaudeUsage</string></array>
    <key>RunAtLoad</key><true/>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed to $DEST — it's running now and will start at login."
