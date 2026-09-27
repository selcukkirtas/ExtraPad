#!/bin/bash
# Builds the iPad client and runs it in the Simulator.
#
# Compiled with swiftc directly rather than through an Xcode project: this needs
# no extra tooling and is fully scriptable, which matters while the client is
# being proved out. A real .xcodeproj becomes necessary for App Store
# submission and is a Phase D job.
#
# The shared protocol sources are compiled in alongside the app rather than
# linked as a module - same source of truth, far less build machinery.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$HOME/Library/Caches/ExtraPad-ios"
APP="$BUILD/ExtraPadClient.app"
BUNDLE_ID="dev.extrapad.client"
DEVICE="${EXTRAPAD_SIM_DEVICE:-iPad Air 11-inch (M4)}"

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET="arm64-apple-ios15.0-simulator"

echo "==> compiling for $TARGET"
rm -rf "$APP"
mkdir -p "$APP"
xcrun -sdk iphonesimulator swiftc \
  -target "$TARGET" -sdk "$SDK" \
  -swift-version 5 \
  -emit-executable -o "$APP/ExtraPadClient" \
  "$ROOT"/Sources/ExtraPadClient/*.swift \
  "$ROOT"/Sources/ExtraPadProtocol/*.swift

cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>ExtraPad</string>
    <key>CFBundleDisplayName</key>        <string>ExtraPad</string>
    <key>CFBundleExecutable</key>         <string>ExtraPadClient</string>
    <key>CFBundleIdentifier</key>         <string>dev.extrapad.client</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1.0</string>
    <key>CFBundleVersion</key>            <string>1</string>
    <key>MinimumOSVersion</key>           <string>15.0</string>
    <key>UILaunchScreen</key>             <dict/>
    <key>UIRequiresFullScreen</key>       <true/>
    <key>UISupportedInterfaceOrientations</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
    <!-- Browsing for the Mac needs both of these, and iOS shows the user a
         prompt the first time. Without them the browser returns nothing and
         never explains why. -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>ExtraPad looks for your Mac on this network so your iPad can become a second display.</string>
    <key>NSBonjourServices</key>
    <array><string>_extrapad._tcp</string></array>
</dict>
</plist>
PLIST

echo "==> booting simulator: $DEVICE"
UDID="$(xcrun simctl list devices available | grep -m1 -F "$DEVICE (" | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
if [ -z "$UDID" ]; then echo "ERROR: simulator '$DEVICE' not found" >&2; exit 1; fi
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || xcrun simctl boot "$UDID" >/dev/null 2>&1 || true

echo "==> installing"
xcrun simctl install "$UDID" "$APP"
echo "==> launching"
xcrun simctl launch "$UDID" "$BUNDLE_ID"
echo
echo "Ready. Simulator UDID: $UDID"
