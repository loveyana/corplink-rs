#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
PKG="$ROOT/CorplinkGUI"
APP="$ROOT/CorplinkGUI.app"
BIN_OUT="$PKG/.build/release/CorplinkGUI"
ICNS="$ROOT/Resources/AppIcon.icns"

chmod +x "$ROOT/scripts/"*.sh

cd "$PKG"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_OUT" "$APP/Contents/MacOS/CorplinkGUI"
if [[ -f "$ICNS" ]]; then
  cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
fi

cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>CorplinkGUI</string>
  <key>CFBundleIdentifier</key>
  <string>local.corplink.rs.gui</string>
  <key>CFBundleName</key>
  <string>CorpLink RS</string>
  <key>CFBundleDisplayName</key>
  <string>CorpLink RS</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleShortVersionString</key>
  <string>0.2.0</string>
  <key>CFBundleVersion</key>
  <string>2</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <false/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

# Touch to refresh Dock/LaunchServices icon cache for this path
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true

echo "Built: $APP"
echo "Run:   open \"$APP\""
