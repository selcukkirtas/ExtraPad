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

echo "==> bundling: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/ExtraPad"
cp "$ROOT/Sources/ExtraPad/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

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
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>    <string>0.1.0</string>
    <key>CFBundleVersion</key>               <string>1</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>
    <!-- Menu bar only, no Dock icon. -->
    <key>LSUIElement</key>                   <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>ExtraPad needs your local network to send the screen to your iPad.</string>
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

# Distribution builds need a "Developer ID Application" certificate, which only
# a paid Apple Developer Program membership can create. When one is present we
# sign for distribution - hardened runtime, secure timestamp - which is what
# notarization requires. Otherwise we fall back to a development certificate,
# which is fine for running it on this machine but not for shipping.
IDENTITY="${EXTRAPAD_IDENTITY:-}"
DISTRIBUTION=0

if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
              | grep -m1 -oE '"Developer ID Application: [^"]+"' | tr -d '"')" || true
  [ -n "$IDENTITY" ] && DISTRIBUTION=1
fi
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
              | grep -m1 -oE '"Apple Development: [^"]+"' | tr -d '"')" || true
fi

if [ "$DISTRIBUTION" = "1" ]; then
  echo "==> signing for distribution: $IDENTITY"
  # Hardened runtime is mandatory for notarization. The private CoreGraphics
  # classes this app uses are not affected by it - that restriction belongs to
  # App Review, which this route does not go through.
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP" >/dev/null
elif [ -n "$IDENTITY" ]; then
  echo "==> signing for local use: $IDENTITY"
  echo "    (no Developer ID certificate found - this build cannot be notarized)"
  codesign --force --sign "$IDENTITY" --timestamp=none "$APP" >/dev/null
else
  echo "==> signing ad-hoc (no code signing certificate found)"
  echo "    WARNING: you will have to grant Screen Recording again after every build."
  codesign --force --sign - --timestamp=none "$APP" >/dev/null
fi

codesign --verify --strict "$APP" || { echo "ERROR: signature could not be verified"; exit 1; }

# Notarization: Apple scans the build and issues a ticket, which is then stapled
# into the bundle so macOS accepts it offline. Without this, a downloaded app is
# blocked by Gatekeeper no matter how it is signed.
#
# One-time setup, once a paid membership exists:
#   xcrun notarytool store-credentials extrapad \
#     --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PASSWORD
# Then: EXTRAPAD_NOTARY_PROFILE=extrapad ./scripts/build-app.sh
if [ -n "${EXTRAPAD_NOTARY_PROFILE:-}" ]; then
  if [ "$DISTRIBUTION" != "1" ]; then
    echo "ERROR: notarization needs a Developer ID Application certificate" >&2
    exit 1
  fi
  ZIP="$APP_DIR/ExtraPad.zip"
  echo "==> submitting for notarization (this takes a few minutes)"
  /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$EXTRAPAD_NOTARY_PROFILE" --wait
  echo "==> stapling the ticket"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  # Re-zip so the distributed archive contains the stapled bundle.
  rm -f "$ZIP"
  /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
  echo "==> ready to distribute: $ZIP"
  echo "    Verify as a user would:  spctl --assess --type execute -vv \"$APP\""
fi

# Convenience pointer so the app is still reachable from the project directory.
mkdir -p "$ROOT/build"
rm -f "$ROOT/build/ExtraPad.app"
ln -s "$APP" "$ROOT/build/ExtraPad.app"

echo
echo "Ready: $APP"
echo "Run:       open \"$APP\""
echo "For logs:  \"$APP/Contents/MacOS/ExtraPad\""
