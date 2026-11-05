#!/usr/bin/env bash
# Builds ClaudeUsage.app into ./build
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP="build/ClaudeUsage.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/ClaudeUsage" "$APP/Contents/MacOS/ClaudeUsage"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $APP"
