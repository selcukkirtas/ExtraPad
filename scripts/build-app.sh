#!/bin/bash
# Builds ExtraPad.app. A real bundle (not the bare SPM binary) is required:
# macOS grants Screen Recording and Local Network permission per bundle identity,
# and LSUIElement is what keeps the app out of the Dock.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Deliberately outside the project: if the repo sits in iCloud Drive (~/Documents
# and ~/Desktop do by default), the file provider stamps com.apple.FinderInfo onto
# the bundle while codesign is sealing it, and signing fails every time. A stable
# path also keeps the app's identity - and therefore its permissions - put.
APP_DIR="$HOME/Library/Application Support/ExtraPad"
APP="$APP_DIR/ExtraPad.app"
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

# Signing identity matters more than it looks: macOS ties the Screen Recording
# permission to the app's code identity. An ad-hoc signature (-) changes its
# cdhash on every rebuild, so the permission is revoked each time you build. A
# real certificate keeps the identity stable, so you grant the permission once.
# codesign refuses a bundle carrying Finder metadata, and iCloud Drive (this
# project may well live under ~/Documents) stamps com.apple.FinderInfo onto it.
# `xattr -c` does not clear FinderInfo; deleting it by name does.
find "$APP" -name '.DS_Store' -delete 2>/dev/null || true
xattr -cr "$APP" 2>/dev/null || true
xattr -rd com.apple.FinderInfo "$APP" 2>/dev/null || true

IDENTITY="${EXTRAPAD_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
              | grep -m1 -oE '"Apple Development: [^"]+"' | tr -d '"')" || true
fi

if [ -n "$IDENTITY" ]; then
  echo "==> imzalaniyor: $IDENTITY"
  codesign --force --sign "$IDENTITY" --timestamp=none "$APP" >/dev/null
else
  echo "==> ad-hoc imzalaniyor (kod imzalama sertifikasi bulunamadi)"
  echo "    UYARI: her derlemeden sonra Ekran Kaydi iznini yeniden vermeniz gerekecek."
  codesign --force --sign - --timestamp=none "$APP" >/dev/null
fi

codesign --verify --strict "$APP" || { echo "HATA: imza dogrulanamadi"; exit 1; }

# Convenience pointer so the app is still reachable from the project directory.
mkdir -p "$ROOT/build"
rm -f "$ROOT/build/ExtraPad.app"
ln -s "$APP" "$ROOT/build/ExtraPad.app"

echo
echo "Hazir: $APP"
echo "Calistir:  open \"$APP\""
echo "Loglari gormek icin: \"$APP/Contents/MacOS/ExtraPad\""
