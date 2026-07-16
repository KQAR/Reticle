#!/usr/bin/env bash
# Build an iOS sample app product into a runnable .app bundle and install it on a
# simulator. SwiftPM builds the Mach-O; this script wraps it with an Info.plist
# (SwiftPM does not emit .app bundles) and installs via simctl.
#
# Usage:
#   scripts/build-sample-ios.sh <SampleApp|SampleAppNoAgent> <bundle-id> [udid]
#
# Examples:
#   scripts/build-sample-ios.sh SampleApp        dev.reticle.sampleios
#   scripts/build-sample-ios.sh SampleAppNoAgent dev.reticle.sampleios.noagent
set -euo pipefail

PRODUCT="${1:?product name required (SampleApp or SampleAppNoAgent)}"
BUNDLE_ID="${2:?bundle id required}"
DEPLOY="15.0"
ARCH="$(uname -m)"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TRIPLE="${ARCH}-apple-ios${DEPLOY}-simulator"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/sample-app-ios"

echo "Building $PRODUCT for $TRIPLE"
swift build --product "$PRODUCT" \
  --sdk "$SDK" \
  -Xswiftc -target -Xswiftc "$TRIPLE" \
  -Xcc -target -Xcc "$TRIPLE" -Xcc -isysroot -Xcc "$SDK"

BIN_DIR="$(swift build --product "$PRODUCT" --sdk "$SDK" \
  -Xswiftc -target -Xswiftc "$TRIPLE" -Xcc -target -Xcc "$TRIPLE" -Xcc -isysroot -Xcc "$SDK" \
  --show-bin-path)"
BIN="$BIN_DIR/$PRODUCT"
[ -f "$BIN" ] || { echo "built binary not found at $BIN"; exit 1; }

APP="$ROOT/sample-app-ios/.build/bundles/$PRODUCT.app"
rm -rf "$APP"; mkdir -p "$APP"
cp "$BIN" "$APP/$PRODUCT"

cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$PRODUCT</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$PRODUCT</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>MinimumOSVersion</key><string>$DEPLOY</string>
  <key>UIDeviceFamily</key><array><integer>1</integer></array>
  <key>DTPlatformName</key><string>iphonesimulator</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
  <key>UILaunchScreen</key><dict/>
  <key>ReticleAgentEnabled</key><true/>
</dict>
</plist>
PLIST

UDID="${3:-}"
if [ -z "$UDID" ]; then
  UDID="$(xcrun simctl list devices booted -j | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; ids=[x["udid"] for r in d.values() for x in r if x.get("state")=="Booted"]; print(ids[0] if ids else "")')"
fi
if [ -z "$UDID" ]; then
  echo "no booted simulator; boot one and pass its udid, or:"
  echo "  xcrun simctl boot <udid> && open -a Simulator"
  echo "Built bundle: $APP"
  exit 0
fi

echo "Installing $APP on $UDID"
xcrun simctl install "$UDID" "$APP"
echo "Installed $BUNDLE_ID on $UDID"
echo "APP_BUNDLE=$APP"
