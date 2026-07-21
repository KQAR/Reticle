#!/usr/bin/env bash
# End-to-end smoke test for the iOS agent on a REAL DEVICE (linked path).
# Validated on an iPhone 13 Pro Max (iOS 26) with a personal signing cert.
#
# Prereqs (interactive, one-time):
#   - An Apple ID signed into Xcode (Settings > Accounts) whose team owns a
#     signing cert — automatic signing needs the ACCOUNT present, not just a
#     cert in the keychain. `xcodebuild` errors "No Account for Team <id>" when
#     the account is missing; pass a team that IS signed in.
#   - Device paired, Developer Mode on, the developer cert TRUSTED on-device
#     (Settings > General > VPN & Device Management) after the first install.
#   - The device UNLOCKED at launch time and ideally Auto-Lock = Never: iOS
#     refuses `devicectl process launch` on a locked device, and a backgrounded
#     app is suspended (its loopback socket dies), so keep the app foreground.
#   - A free account allows only 3 installed dev apps per device — free a slot.
#   - iproxy (brew install libimobiledevice): a real device's loopback is NOT the
#     host's, so agent traffic is tunneled over USB.
#
# Usage: scripts/e2e-ios-device.sh <team-id> [device-udid|auto] [bundle-id]
#   team-id     : DEVELOPMENT_TEAM with a signed-in Xcode account
#                 (security find-identity -p codesigning -v shows certs;
#                  the team must additionally be signed into Xcode).
#   device-udid : defaults to `auto` -> `idevice_id -l`. IMPORTANT: use this
#                 (the hardware ECID, e.g. 00008110-...). It is the one id that
#                 works for xcodebuild `-destination id=`, `devicectl --device`,
#                 AND `iproxy -u`. The `devicectl list devices` "coredevice UUID"
#                 does NOT match an xcodebuild destination.
set -euo pipefail

TEAM="${1:?team id (see usage — must be signed into Xcode)}"
DEV_ARG="${2:-auto}"
BUNDLE="${3:-dev.reticle.sampleios}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${RETICLE_HOST:-$ROOT/reticle-host/.build/debug/ReticleHost}"
DD="$HOME/Library/Developer/Xcode/DerivedData/SampleAppIOS-dev"

command -v iproxy >/dev/null || { echo "iproxy not found (brew install libimobiledevice)"; exit 1; }
command -v idevice_id >/dev/null || { echo "idevice_id not found (brew install libimobiledevice)"; exit 1; }
[ -x "$HOST" ] || { echo "build the host first: swift build --package-path reticle-host"; exit 1; }

if [ "$DEV_ARG" = "auto" ]; then
  DEV_UDID="$(idevice_id -l 2>/dev/null | head -1)"
else
  DEV_UDID="$DEV_ARG"
fi
[ -n "$DEV_UDID" ] || { echo "no device found (idevice_id -l empty); connect + trust a device"; exit 1; }
echo "device: $DEV_UDID  team: $TEAM  bundle: $BUNDLE"

PORT="$(/usr/bin/python3 -c 'x=0x811C9DC5
for b in "'"$BUNDLE"'".encode(): x^=b; x=(x*0x01000193)&0xFFFFFFFF
print(8765+(x%1000))')"

# A locked device rejects launch — surface it early rather than failing opaquely.
if xcrun devicectl device info lockState --device "$DEV_UDID" 2>/dev/null | grep -q "passcodeRequired: true"; then
  echo "device is LOCKED — unlock it (and set Auto-Lock = Never) before running"; exit 1
fi

echo "== build + sign SampleApp for device (team $TEAM) =="
( cd "$ROOT/sample-app-ios/xcode" && xcodegen generate >/dev/null )
xcodebuild -project "$ROOT/sample-app-ios/xcode/SampleAppIOS.xcodeproj" -scheme SampleApp \
  -destination "platform=iOS,id=$DEV_UDID" -derivedDataPath "$DD" -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE" build >/dev/null
APP="$DD/Build/Products/Debug-iphoneos/SampleApp.app"

echo "== install + launch =="
xcrun devicectl device install app --device "$DEV_UDID" "$APP" >/dev/null
xcrun devicectl device process launch --device "$DEV_UDID" --terminate-existing "$BUNDLE" >/dev/null

echo "== USB tunnel host:$PORT -> device:$PORT =="
pkill -f "iproxy .*$PORT" 2>/dev/null || true
iproxy -u "$DEV_UDID" "$PORT:$PORT" >/dev/null 2>&1 & IPROXY=$!
trap 'kill $IPROXY 2>/dev/null || true' EXIT

OUT="$(mktemp -d)"

echo "== wait for the in-process agent (app must stay foreground) =="
READY=0
for _ in $(seq 1 12); do
  sleep 1
  if "$HOST" --target ios status --package "$BUNDLE" 2>/dev/null | grep -q "runtime: healthy"; then READY=1; break; fi
done
[ "$READY" = 1 ] || { echo "FAIL: agent never became reachable over the tunnel (app suspended? device asleep?)"; exit 1; }
"$HOST" --target ios status --package "$BUNDLE"

echo "== observation over the tunnel =="
"$HOST" --target ios ui report --package "$BUNDLE" --output "$OUT/report"
"$HOST" --target ios ui compact "$OUT/report/snapshot.json"
"$HOST" --target ios ui screenshot --package "$BUNDLE" --output "$OUT/shot.png"

# SwiftUI accessibility elements (axElements carrying .accessibilityIdentifier)
# build LAZILY on a real device — only once the app's accessibility runtime is
# engaged. The agent now engages it at startup (`_AXSSetAutomationEnabled(true)`,
# the same flag XCUITest sets), so `.accessibilityIdentifier`s surface on the
# first observation without any warm-up action. Poll briefly as a defensive
# backstop for the asynchronous tree build.
echo "== confirm SwiftUI axElements are present (agent engages AX at startup) =="
AX_READY=0
for _ in $(seq 1 10); do
  "$HOST" --target ios ui report --package "$BUNDLE" --output "$OUT/warm" >/dev/null 2>&1 || true
  if grep -q "scenario.checkout" "$OUT/warm/snapshot.json" 2>/dev/null; then AX_READY=1; break; fi
  sleep 1
done
[ "$AX_READY" = 1 ] || { echo "FAIL: SwiftUI axElements never surfaced (agent AX engage failed?)"; exit 1; }
echo "accessibility tree ready"

# Navigate into the Checkout scenario via in-process activation — the device
# analogue of a tap (no HID surface on a real phone). `--trace-output` also
# exercises the action-trace evidence package end-to-end on the device.
echo "== act activate + action-trace over the tunnel =="
"$HOST" --target ios act activate --package "$BUNDLE" --test-id scenario.checkout --trace-output "$OUT/trace"
sleep 1
"$HOST" --target ios mutate --package "$BUNDLE" --test-id checkout.payButton --property alpha --value 0.35

TRACE_JSON="$(find "$OUT/trace" -name trace.json | head -1)"
[ -n "$TRACE_JSON" ] || { echo "FAIL: no action-trace manifest written on device"; exit 1; }
grep -q '"platform":"ios"' "$TRACE_JSON" || grep -q '"platform": "ios"' "$TRACE_JSON" \
  || { echo "FAIL: trace.json missing platform=ios"; exit 1; }
TDIR="$(dirname "$TRACE_JSON")"
[ -f "$TDIR/before.snapshot.json" ] && [ -f "$TDIR/after.snapshot.json" ] \
  && [ -f "$TDIR/before.screenshot.png" ] && [ -f "$TDIR/after.screenshot.png" ] \
  || { echo "FAIL: trace missing before/after snapshot+screenshot artifacts"; exit 1; }
echo "action-trace evidence package written on device: $TDIR"

echo "== TAB BAR scenario (SwiftUI TabView, device) =="
# Relaunch straight into the tabbar scenario via the env deep-link; a fresh
# process keeps this section independent of the navigation state left above.
xcrun devicectl device process launch --device "$DEV_UDID" --terminate-existing \
  --environment-variables '{"RETICLE_SAMPLE_SCENARIO":"tabbar"}' "$BUNDLE" >/dev/null
READY=0
for _ in $(seq 1 12); do
  sleep 1
  if "$HOST" --target ios status --package "$BUNDLE" 2>/dev/null | grep -q "runtime: healthy"; then READY=1; break; fi
done
[ "$READY" = 1 ] || { echo "FAIL: agent not reachable after tabbar relaunch"; exit 1; }
# Poll until the tab page's SwiftUI content folds in as axElements — the device
# regression guard for the unlabeled-AX-container flatten (a TabView page host
# wraps the whole page in ONE unlabeled AX container) compounded with the lazy
# real-device AX tree build.
TAB_READY=0
for _ in $(seq 1 10); do
  "$HOST" --target ios ui report --package "$BUNDLE" --output "$OUT/tabbar" >/dev/null 2>&1 || true
  if grep -q "tabbar.status" "$OUT/tabbar/snapshot.json" 2>/dev/null; then TAB_READY=1; break; fi
  sleep 1
done
[ "$TAB_READY" = 1 ] || { echo "FAIL: tab page SwiftUI content never folded in (unlabeled AX container regression?)"; exit 1; }
TABBAR="$("$HOST" --target ios ui compact "$OUT/tabbar/snapshot.json")"
for item in Home Orders Messages Profile; do
  echo "$TABBAR" | grep -q "control \"$item\"" \
    || { echo "FAIL: expected tab bar item \"$item\" (UITabBar view walk)"; exit 1; }
done
echo "$TABBAR" | grep -q "Selected: home" \
  || { echo "FAIL: tabbar.status should read 'Selected: home' before any switch"; exit 1; }
# Switch tabs via in-process activation (sendActions on the UIControl) — HID
# does not exist on a real device. Observable side effect: the page swaps and
# tabbar.status flips to "Selected: orders".
ORDERS_REF="$(/usr/bin/python3 -c 'import json
s=json.load(open("'"$OUT"'/tabbar/snapshot.json"))
print(next(r for r,v in s["nodes"].items()
  if "Tab" in str(v.get("typeName","")) and "Button" in str(v.get("typeName",""))
  and v.get("contentDescription")=="Orders"))')"
"$HOST" --target ios act activate --package "$BUNDLE" --ref "$ORDERS_REF"
sleep 1
"$HOST" --target ios ui report --package "$BUNDLE" --output "$OUT/tabbar-orders"
"$HOST" --target ios ui compact "$OUT/tabbar-orders/snapshot.json" | grep -q "Selected: orders" \
  || { echo "FAIL: activating the Orders tab did not update tabbar.status"; exit 1; }

echo "== OK (HID gestures are NOT available on a real device; activation is) — artifacts in $OUT =="
