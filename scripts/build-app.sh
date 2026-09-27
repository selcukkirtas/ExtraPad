#!/bin/bash
# Builds ExtraPad.app. A real bundle (not the bare SPM binary) is required:
# macOS grants Screen Recording and Local Network permission per bundle identity,
# and LSUIElement is what keeps the app out of the Dock.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/ExtraPad.app"
CONFIGURATION="${1:-release}"

echo "==> swift build -c $CONFIGURATION"
swift build --package-path "$ROOT" -c "$CONFIGURATION"
BINARY="$(swift build --package-path "$ROOT" -c "$CONFIGURATION" --show-bin-path)/ExtraPad"

echo "==> paketleniyor: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/ExtraPad"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>ExtraPad</string>
    <key>CFBundleDisplayName</key>           <string>ExtraPad</string>
    <key>CFBundleExecutable</key>            <string>ExtraPad</string>
    <key>CFBundleIdentifier</key>            <string>dev.extrapad.app</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>0.1.0</string>
    <key>CFBundleVersion</key>               <string>1</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>
    <!-- Menu bar only, no Dock icon. -->
    <key>LSUIElement</key>                   <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>iPad'inize ekran goruntusu gondermek icin yerel aginiza erisim gerekir.</string>
    <key>NSBonjourServices</key>
    <array><string>_http._tcp</string></array>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for a locally built app. Note that re-signing after a
# rebuild can make macOS ask for Screen Recording permission again.
echo "==> ad-hoc imzalaniyor"
codesign --force --sign - --timestamp=none "$APP" >/dev/null

echo
echo "Hazir: $APP"
echo "Calistir:  open \"$APP\""
echo "Loglari gormek icin: \"$APP/Contents/MacOS/ExtraPad\""
