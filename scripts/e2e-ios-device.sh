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
# Reuse the SwiftPM checkouts the simulator path already has. Xcode keeps its own
# SPM state under DerivedData and does NOT share the `swift build` cache, so a
# fresh DerivedData re-mirrors every dependency — lottie-ios alone is a ~176M
# full-history clone, minutes of network for bytes already on disk. Point Xcode at
# a COPY (not sample-app-ios/.build itself: Xcode rewrites workspace-state.json,
# and the simulator path's state is not ours to churn).
SPM_DIR="$ROOT/sample-app-ios/.build"
CLONED_SPM=""
if [ -d "$SPM_DIR/checkouts" ]; then
  CLONED_SPM="$(mktemp -d)/spm"
  cp -R "$SPM_DIR" "$CLONED_SPM"
  echo "reusing SwiftPM checkouts from $SPM_DIR (copy: $CLONED_SPM)"
fi
xcodebuild -project "$ROOT/sample-app-ios/xcode/SampleAppIOS.xcodeproj" -scheme SampleApp \
  -destination "platform=iOS,id=$DEV_UDID" -derivedDataPath "$DD" -allowProvisioningUpdates \
  ${CLONED_SPM:+-clonedSourcePackagesDirPath "$CLONED_SPM"} \
  DEVELOPMENT_TEAM="$TEAM" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE" build >/dev/null
APP="$DD/Build/Products/Debug-iphoneos/SampleApp.app"

echo "== install + launch =="
xcrun devicectl device install app --device "$DEV_UDID" "$APP" >/dev/null
xcrun devicectl device process launch --device "$DEV_UDID" --terminate-existing "$BUNDLE" >/dev/null

echo "== USB tunnel host:$PORT -> device:$PORT =="
pkill -f "iproxy .*$PORT" 2>/dev/null || true
# The port is derived from the bundle id, so the SAME app on a booted simulator
# listens on the SAME host port — and a simulator shares the host loopback. If
# anything already holds it, iproxy cannot bind and every command below silently
# talks to that process instead of to the phone. Measured: a leftover simulator
# app answered `status: healthy` and served ITS screen over the "tunnel", and the
# run failed further down on an assertion about content that was never on the
# device. Refuse instead.
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "FAIL: host port $PORT is already in use — the tunnel would not bind and every"
  echo "      command would hit that process instead of the device. Most likely the same"
  echo "      app on a booted simulator (same bundle id -> same derived port):"
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN | sed 's/^/      /'
  echo "      Terminate it (xcrun simctl terminate <udid> $BUNDLE) and re-run."
  exit 1
fi
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

echo "== COORDINATE GESTURES ON A PHONE (in-process touch synthesis) =="
# The gap that used to be structural: no HID surface is reachable from the host, so
# a point tap, a `--region` tap, a swipe and `scroll-to` were all refused by name.
# The agent runs inside the app, so it synthesizes the touch there — a `UITouch` in
# the application's own `UITouchesEvent`, sent through `-sendEvent:`, which is the
# call UIKit makes for a finger. Hit-testing, gesture recognizers and scroll views
# therefore behave as they do under one, and that is what every assertion here
# checks: the app's own handler, not the dispatch reporting success.
#
# `--serial "$DEV_UDID"` for the same reason as typing: an input gesture must name
# where to dispatch, or the host falls back to a booted simulator.
xcrun devicectl device process launch --device "$DEV_UDID" --terminate-existing \
  --environment-variables '{"RETICLE_SAMPLE_SCENARIO":"agreements"}' "$BUNDLE" >/dev/null
READY=0
for _ in $(seq 1 12); do
  sleep 1
  if "$HOST" --target ios status --package "$BUNDLE" 2>/dev/null | grep -q "runtime: healthy"; then READY=1; break; fi
done
[ "$READY" = 1 ] || { echo "FAIL: agent not reachable after agreements relaunch"; exit 1; }

# A text-range region, which has NO in-process activation surface and was therefore
# unreachable on a device: per-phrase, and the app names the phrase it received, so
# a rect that is merely plausible fails here.
MARKER_TAP="$("$HOST" --target ios --serial "$DEV_UDID" act tap --package "$BUNDLE" \
  --test-id agreement.markdown --region "«Privacy»")"
echo "$MARKER_TAP"
echo "$MARKER_TAP" | grep -q "source=region:textMarker" \
  || { echo "FAIL: the region tap must report how it resolved; got: $MARKER_TAP"; exit 1; }
"$HOST" --target ios ui compact --live --package "$BUNDLE" | grep -q 'opened «Privacy» (markdown link)' \
  || { echo "FAIL: tapping the «Privacy» marker did not fire the app's link handler"; exit 1; }
# The char grid too: a plain phrase with no markers at all.
"$HOST" --target ios --serial "$DEV_UDID" act tap --package "$BUNDLE" \
  --test-id agreement.plain --region "Privacy Policy" >/dev/null
sleep 1
"$HOST" --target ios ui compact --live --package "$BUNDLE" | grep -q "opened Privacy Policy (plain phrase)" \
  || { echo "FAIL: a char-grid region tap did not reach the phrase handler"; exit 1; }
# And the row whose behaviour lives in a UIGestureRecognizer — proven unreachable
# by activation earlier in this suite, reachable by a real touch.
POINT_TAP="$("$HOST" --target ios --serial "$DEV_UDID" act tap --package "$BUNDLE" --point 214,427)"
echo "$POINT_TAP"
echo "$POINT_TAP" | grep -q "via=agent uikit" \
  || { echo "FAIL: a device coordinate tap must go through the agent's touch surface"; exit 1; }
"$HOST" --target ios ui compact --live --package "$BUNDLE" | grep -q "tapped color row (manual hit-test)" \
  || { echo "FAIL: the gesture-recognizer row must be reachable by a real touch"; exit 1; }

# `scroll-to`: the gesture a device needed most, since a lazy list's unrealized row
# has no node at all until something scrolls it into view — and activation cannot
# scroll. `list.item55` is absent at launch; the assertion is that it resolves after.
xcrun devicectl device process launch --device "$DEV_UDID" --terminate-existing \
  --environment-variables '{"RETICLE_SAMPLE_SCENARIO":"list"}' "$BUNDLE" >/dev/null
sleep 5
"$HOST" --target ios ui report --package "$BUNDLE" --output "$OUT/list-before" >/dev/null
grep -q "list.item55" "$OUT/list-before/snapshot.json" \
  && { echo "FAIL: list.item55 should NOT be realized at launch (the premise of this check)"; exit 1; }
SCROLLED="$("$HOST" --target ios --serial "$DEV_UDID" act scroll-to --package "$BUNDLE" --test-id list.item55)"
echo "$SCROLLED"
echo "$SCROLLED" | grep -q "found=true" \
  || { echo "FAIL: scroll-to must realize a row a lazy list had not built; got: $SCROLLED"; exit 1; }
echo "$SCROLLED" | grep -q "via=agent uikit" \
  || { echo "FAIL: scroll-to on a device must drag through the agent's touch surface"; exit 1; }
# A swipe, reported with the surface that carried it.
SWIPED="$("$HOST" --target ios --serial "$DEV_UDID" act swipe --package "$BUNDLE" \
  --from 214,700 --to 214,300 --duration 400)"
echo "$SWIPED" | grep -q "via=agent uikit" \
  || { echo "FAIL: a device swipe must go through the agent's touch surface; got: $SWIPED"; exit 1; }

echo "== ACTIVATION IS THREE-STATE (what in-process driving can and cannot reach) =="
# Measured on this device and the reason `unconfirmed` exists: a UITextView holding
# a `.link` run OPENS that link (its delegate runs, the status label changes) and
# answers `false` to accessibilityActivate() anyway. That used to be reported as
# `error: unsupported_activation_target` with exit 1 — a lie about a screen that had
# already acted — and because the host threw, --verify recorded nothing.
xcrun devicectl device process launch --device "$DEV_UDID" --terminate-existing \
  --environment-variables '{"RETICLE_SAMPLE_SCENARIO":"agreements"}' "$BUNDLE" >/dev/null
READY=0
for _ in $(seq 1 12); do
  sleep 1
  if "$HOST" --target ios status --package "$BUNDLE" 2>/dev/null | grep -q "runtime: healthy"; then READY=1; break; fi
done
[ "$READY" = 1 ] || { echo "FAIL: agent not reachable after agreements relaunch"; exit 1; }
SPAN_OUT="$("$HOST" --target ios act activate --package "$BUNDLE" --test-id agreement.span \
  --verify '#agreement.status')"
echo "$SPAN_OUT"
echo "$SPAN_OUT" | grep -q "outcome=unconfirmed" \
  || { echo "FAIL: a dispatched-but-unacknowledged activation must read unconfirmed, got: $SPAN_OUT"; exit 1; }
# The point of not throwing: --verify RAN, and it is what proves the link opened.
echo "$SPAN_OUT" | grep -q "opened agreement (link attribute)" \
  || { echo "FAIL: --verify must show the side effect the Bool denied"; exit 1; }

# The other half of the same honesty: a row whose behaviour lives in a gesture
# recognizer is genuinely unreachable in-process, and the evidence — not the Bool —
# is what says so. `unchanged` here is the correct, useful answer.
COLOR_OUT="$("$HOST" --target ios act activate --package "$BUNDLE" --test-id agreement.color \
  --verify '#agreement.status')"
echo "$COLOR_OUT"
echo "$COLOR_OUT" | grep -q "outcome=unconfirmed" \
  || { echo "FAIL: the gesture-recognizer row must also read unconfirmed, got: $COLOR_OUT"; exit 1; }
echo "$COLOR_OUT" | grep -q "unchanged" \
  || { echo "FAIL: --verify must report the watched node unchanged for a row nothing drove"; exit 1; }

# A text-range region has no in-process surface at all: nothing was dispatched, so
# this one MUST still be an error rather than an unconfirmed guess.
if "$HOST" --target ios act activate --package "$BUNDLE" --test-id agreement.color \
     --region "Terms of Service" >/dev/null 2>&1; then
  echo "FAIL: a text-range region must be refused, not reported as attempted"; exit 1
fi

# a11yVirtual: BOTH accessibility-container conventions must be ASKED the same way
# they were discovered (the array-only reader refused the container-methods one for a
# reason that was Reticle's). Neither activates in this app — its virtual elements
# implement touch handling — so both must read unconfirmed, never "no surface".
xcrun devicectl device process launch --device "$DEV_UDID" --terminate-existing \
  --environment-variables '{"RETICLE_SAMPLE_SCENARIO":"canvasControl"}' "$BUNDLE" >/dev/null
sleep 4
for pair in "canvas.segments|Weekly" "canvas.seats|A3"; do
  CID="${pair%%|*}"; CREG="${pair##*|}"
  CANVAS_OUT="$("$HOST" --target ios act activate --package "$BUNDLE" --test-id "$CID" --region "$CREG" \
    --verify '#canvas.status')"
  echo "$CANVAS_OUT" | grep -q "outcome=unconfirmed" \
    || { echo "FAIL: a11yVirtual region $CID/$CREG must be attempted (unconfirmed), got: $CANVAS_OUT"; exit 1; }
done

echo "== IN-PROCESS TYPING (no HID on a phone) =="
# The device path for `act type`: the host cannot synthesize keys, so the agent
# hands them to the app through `UIKeyInput.insertText`. Every assertion below is
# an observable side effect, never the result claiming success.
#
# `--serial "$DEV_UDID"` is REQUIRED here and the suite caught why: observation
# goes over the tunnel and needs no serial, but an input gesture must know WHERE
# to dispatch, and with no serial the host falls back to the booted SIMULATOR.
# Measured on the first device run of this section: the keystrokes went to the
# simulator's screen and the result read `via=hid` while the phone's field stayed
# empty. Naming the device (its hardware ECID) is what makes it the target.
xcrun devicectl device process launch --device "$DEV_UDID" --terminate-existing \
  --environment-variables '{"RETICLE_SAMPLE_SCENARIO":"login"}' "$BUNDLE" >/dev/null
READY=0
for _ in $(seq 1 12); do
  sleep 1
  if "$HOST" --target ios status --package "$BUNDLE" 2>/dev/null | grep -q "runtime: healthy"; then READY=1; break; fi
done
[ "$READY" = 1 ] || { echo "FAIL: agent not reachable after login relaunch"; exit 1; }
TYPED="$("$HOST" --target ios --serial "$DEV_UDID" act type --package "$BUNDLE" --test-id login.codeField --text "123456")"
echo "$TYPED"
echo "$TYPED" | grep -q "via=agent insertText" \
  || { echo "FAIL: a real device must type in-process, got: $TYPED"; exit 1; }
"$HOST" --target ios ui compact --live --package "$BUNDLE" | grep "login.codeField" | grep -q "123456" \
  || { echo "FAIL: in-process typing did not land the code in the field"; exit 1; }
# Focusing in-process raises the REAL system keyboard — on a phone there is no
# hardware-keyboard artifact to muddy this, so the state channel is asserted here.
echo "$TYPED" | grep -q "keyboardVisible=true" \
  || { echo "FAIL: typing must focus the field, raising the device keyboard"; exit 1; }
"$HOST" --target ios ui compact --live --package "$BUNDLE" | grep "login.submitButton" | grep -q "occluded-by:keyboard" \
  || { echo "FAIL: the keyboard the typing raised must mark the submit button occluded"; exit 1; }
# `--clear` deletes what is there, one backspace per character, and proves it.
CLEARED="$("$HOST" --target ios --serial "$DEV_UDID" act type --package "$BUNDLE" --test-id login.codeField --text "4321" --clear --submit)"
echo "$CLEARED"
echo "$CLEARED" | grep -q "cleared=emptied(6ch)" \
  || { echo "FAIL: --clear must report emptying the 6 characters that were there; got: $CLEARED"; exit 1; }
# `--submit` fires the return key's action with no return key to press.
"$HOST" --target ios ui compact --live --package "$BUNDLE" | grep "login.status" | grep -q "Logged in: 4321" \
  || { echo "FAIL: in-process --submit did not fire the field's return action"; exit 1; }
# Non-ASCII needs no clipboard on this path — `insertText` takes the string whole,
# where the simulator's HID keyboard can only emit printable ASCII.
"$HOST" --target ios --serial "$DEV_UDID" act type --package "$BUNDLE" --test-id login.codeField --text "héllo 世界" --clear >/dev/null
"$HOST" --target ios ui compact --live --package "$BUNDLE" | grep "login.codeField" | grep -q "héllo 世界" \
  || { echo "FAIL: in-process typing must land non-ASCII text as-is"; exit 1; }
"$HOST" --target ios act hide-keyboard --package "$BUNDLE" >/dev/null

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

echo "== OK (no host HID on a real device; touch, typing and activation are all in-process) — artifacts in $OUT =="
