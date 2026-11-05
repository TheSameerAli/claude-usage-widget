#!/usr/bin/env bash
set -euo pipefail
LABEL="local.claude-usage-widget"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x ClaudeUsage 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/ClaudeUsage.app"
echo "Uninstalled."
