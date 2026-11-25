#!/bin/bash
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/Caves of Qud Apple Silicon Launcher.app"
MODULE_CACHE="${TMPDIR:-/tmp}/qud-apple-silicon-launcher-swift-module-cache"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/AppTemplate/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Launch Caves of Qud (Apple Silicon).command" "$APP/Contents/Resources/QudLaunchHelper.command"

/usr/bin/swiftc -O -parse-as-library -target arm64-apple-macosx13.0 \
  -module-cache-path "$MODULE_CACHE" \
  -framework SwiftUI -framework AppKit \
  -o "$APP/Contents/MacOS/QudLauncher" \
  "$ROOT/Sources/LauncherApp.swift"

/usr/bin/xattr -cr "$APP"
/usr/bin/codesign --force --deep --sign - "$APP" >/dev/null
echo "Built: $APP"
