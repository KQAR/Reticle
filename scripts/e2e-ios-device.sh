#!/usr/bin/env bash
# End-to-end smoke test for the iOS agent on a REAL DEVICE (linked path).
# Validated on an iPhone 13 Pro Max (iOS 26) with a free developer account.
#
# Prereqs (interactive, one-time):
#   - A valid Apple ID signed into Xcode (Settings > Accounts) for automatic signing.
#   - Device paired, Developer Mode on, and the developer cert TRUSTED on-device
#     (Settings > General > VPN & Device Management) after the first install.
#   - A free account allows only 3 installed dev apps per device — free a slot if full.
#   - iproxy (brew install libimobiledevice): a real device's loopback is NOT the
#     host's, so agent traffic is tunneled over USB.
#
# Usage: scripts/e2e-ios-device.sh <device-udid> <team-id> [bundle-id]
set -euo pipefail

DEV_UDID="${1:?device udid (xcrun devicectl list devices)}"
TEAM="${2:?team id (security find-identity -p codesigning -v)}"
BUNDLE="${3:-dev.reticle.sampleios}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${RETICLE_HOST:-$ROOT/reticle-host/.build/debug/ReticleHost}"
DD="$HOME/Library/Developer/Xcode/DerivedData/SampleAppIOS-dev"
PORT="$(/usr/bin/python3 -c 'x=0x811C9DC5
for b in "'"$BUNDLE"'".encode(): x^=b; x=(x*0x01000193)&0xFFFFFFFF
print(8765+(x%1000))')"

command -v iproxy >/dev/null || { echo "iproxy not found (brew install libimobiledevice)"; exit 1; }

echo "== build + sign SampleApp for device (team $TEAM) =="
( cd "$ROOT/sample-app-ios/xcode" && xcodegen generate >/dev/null )
xcodebuild -project "$ROOT/sample-app-ios/xcode/SampleAppIOS.xcodeproj" -scheme SampleApp \
  -destination "platform=iOS,id=$DEV_UDID" -derivedDataPath "$DD" -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE" build >/dev/null
APP="$DD/Build/Products/Debug-iphoneos/SampleApp.app"

echo "== install + launch =="
xcrun devicectl device install app --device "$DEV_UDID" "$APP"
xcrun devicectl device process launch --device "$DEV_UDID" "$BUNDLE"
sleep 2

echo "== USB tunnel host:$PORT -> device:$PORT =="
pkill -f "iproxy .*$PORT" 2>/dev/null || true
iproxy -u "$DEV_UDID" "$PORT:$PORT" >/dev/null 2>&1 & IPROXY=$!
trap 'kill $IPROXY 2>/dev/null || true' EXIT
sleep 2

echo "== observation over the tunnel =="
OUT="$(mktemp -d)"
"$HOST" --target ios status --package "$BUNDLE"
"$HOST" --target ios ui report --package "$BUNDLE" --output "$OUT/report"
"$HOST" --target ios ui compact "$OUT/report/snapshot.json"
"$HOST" --target ios ui screenshot --package "$BUNDLE" --output "$OUT/shot.png"
"$HOST" --target ios mutate --package "$BUNDLE" --test-id checkout.payButton --property alpha --value 0.35
echo "== OK (act/HID input is NOT available on a real device) — artifacts in $OUT =="
