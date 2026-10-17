#!/bin/bash
# Builds ClaudeUsageBar.app (menu bar app + desktop widget) into /Applications,
# installs the statusline script and (re)starts the app.
set -euo pipefail
cd "$(dirname "$0")"

APP="/Applications/ClaudeUsageBar.app"

xcodegen generate --quiet
# A new CFBundleVersion on every build, otherwise macOS keeps the old widget.
xcodebuild -project ClaudeUsageBar.xcodeproj -target ClaudeUsageBar -configuration Release \
  SYMROOT="$PWD/build/xcode" CURRENT_PROJECT_VERSION="$(date +%s)" -quiet build

pkill -x ClaudeUsageBar || true
rm -rf "$APP"
ditto build/xcode/Release/ClaudeUsageBar.app "$APP"
# Xcode registers the build product with LaunchServices; a second copy with the same bundle id
# makes chronod drop the widget ("restricted or unknown extension").
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u build/xcode/Release/ClaudeUsageBar.app || true
rm -rf build/xcode/Release/ClaudeUsageBar.app
"$LSREGISTER" -f -R "$APP"
install -m 755 statusline-usage.sh "$HOME/.claude/statusline-usage.sh"

# A widget process from the previous build keeps running the old binary and reports the old
# version, so chronod rejects its timelines ("Bundle version did not match").
pkill -f "$APP/Contents/PlugIns/UsageWidget.appex/Contents/MacOS/UsageWidget" || true
open "$APP"  # reloads widget timelines on launch
echo "Installed $APP"
