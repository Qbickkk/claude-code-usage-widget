#!/bin/bash
# Removes ClaudeUsageBar.app (with its widget), its login item, the statusline script, caches
# and the statusLine setting.
set -uo pipefail

APP="/Applications/ClaudeUsageBar.app"
SETTINGS="$HOME/.claude/settings.json"
BUNDLE_ID="local.shulika-illia.claude-usage-bar"

if [ -x "$APP/Contents/MacOS/ClaudeUsageBar" ]; then
  "$APP/Contents/MacOS/ClaudeUsageBar" --login off >/dev/null 2>&1
fi
pkill -x ClaudeUsageBar
rm -rf "$APP"

# Drop statusLine only if it still points to our script.
if [ "$(/usr/bin/jq -r '.statusLine.command // ""' "$SETTINGS")" = "$HOME/.claude/statusline-usage.sh" ]; then
  /usr/bin/jq 'del(.statusLine)' "$SETTINGS" >"$SETTINGS.tmp" && cat "$SETTINGS.tmp" >"$SETTINGS" && rm -f "$SETTINGS.tmp"
fi
rm -f "$HOME/.claude/statusline-usage.sh" "$HOME/.claude/usage-cache.json" "$HOME/.claude/usage-widget.json"
# Saved API state and any system cache folders for the app.
defaults delete "$BUNDLE_ID" >/dev/null 2>&1
rm -rf "$HOME/Library/Caches/$BUNDLE_ID" "$HOME/Library/HTTPStorages/$BUNDLE_ID"

echo "Removed. Sources are still in $(cd "$(dirname "$0")" && pwd)"
