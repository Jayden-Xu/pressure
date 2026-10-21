#!/bin/bash
# Build Pressure.app with swiftc (no Xcode project), sign it, install to ~/Applications and relaunch.
set -euo pipefail
cd "$(dirname "$0")"

NAME=Pressure
BUNDLE_ID=com.jayden.pressure
VERSION=1.0.3
BUILD=$(date +%Y%m%d%H%M)
MIN_OS=13.0
# Pressure needs no TCC permission, so any identity works; a stable one keeps the login item
# from being treated as a new app after each rebuild. Falls back to ad-hoc.
IDENTITY="${IDENTITY:-Dimmer Dev}"
APP="build/$NAME.app"

echo "==> Compiling"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macos$MIN_OS" \
  -sdk "$(xcrun --show-sdk-path)" \
  -framework AppKit -framework ServiceManagement \
  Sources/*.swift -o "$APP/Contents/MacOS/$NAME"

# icon.swift reuses StatusIcon.drawChip; regenerate only when either file changes.
ICON=build/AppIcon.icns
if [ ! -f "$ICON" ] || [ icon.swift -nt "$ICON" ] || [ Sources/StatusIcon.swift -nt "$ICON" ]; then
  echo "==> Drawing icon"
  rm -rf build/AppIcon.iconset
  swiftc -O -parse-as-library -sdk "$(xcrun --show-sdk-path)" Sources/StatusIcon.swift icon.swift -o build/icon-export
  build/icon-export build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o "$ICON"
  rm -rf build/AppIcon.iconset build/icon-export
fi
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\"" \
   && codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP" 2>/dev/null; then
  echo "    signed with \"$IDENTITY\""
else
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
  echo "    ad-hoc signed"
fi

echo "==> Installing to ~/Applications"
pkill -x "$NAME" 2>/dev/null || true
for _ in $(seq 50); do pgrep -x "$NAME" >/dev/null || break; sleep 0.1; done
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/$NAME.app"
ditto "$APP" "$HOME/Applications/$NAME.app"
# LaunchServices sometimes needs a moment to register the fresh copy (error -600).
for i in 1 2 3 4 5; do open "$HOME/Applications/$NAME.app" 2>/dev/null && break; sleep 0.5; done
echo "==> Done: $HOME/Applications/$NAME.app"
