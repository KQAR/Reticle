#!/usr/bin/env bash
# End-to-end smoke test for the iOS agent on a simulator. Builds the shared
# protocol, the in-process agent, the sample apps, installs them, and exercises
# the full round trip through `reticle --target ios`: linked launch + inject,
# ui report, compact, screenshot, and a mutate verify.
#
# Requires: Xcode + an iOS Simulator runtime, and a built ReticleHost binary
# (swift build --package-path reticle-host). Pass a booted simulator udid as $1,
# or the script boots the first available iPhone.
#
# NOTE (headless caveat): a plain `simctl launch` app gets SUSPENDED on a
# simulator that isn't displayed, which tears down the agent's loopback socket.
# For a reliable run either keep Simulator.app open, or (as this script does for
# the observation steps) hold the app foreground with `simctl launch --console-pty`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
HOST="${RETICLE_HOST:-$ROOT/reticle-host/.build/debug/ReticleHost}"
UDID="${1:-}"
LINKED_ID="dev.reticle.sampleios"
NOAGENT_ID="dev.reticle.sampleios.noagent"
TMP="$(mktemp -d)"

[ -x "$HOST" ] || { echo "build the host first: swift build --package-path reticle-host"; exit 1; }
if [ -z "$UDID" ]; then
  UDID="$(xcrun simctl list devices available -j | /usr/bin/python3 -c 'import json,sys;d=json.load(sys.stdin)["devices"];print(next((x["udid"] for r in d.values() for x in r if "iPhone" in x["name"]),""))')"
fi
[ -n "$UDID" ] || { echo "no iPhone simulator available"; exit 1; }
# The LOGIN scenario needs the on-screen software keyboard. With "Connect
# Hardware Keyboard" on (the Simulator.app default), iOS suppresses it and the
# keyboard-trap assertions can never hold. Turn it off up front; the setting is
# read when the device boots, so a stale-booted sim may still need a reboot
# (the login section fails with a pointer here if so).
defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false
defaults write com.apple.iphonesimulator DevicePreferences -dict-add "$UDID" '{ConnectHardwareKeyboard = 0;}' 2>/dev/null || true
xcrun simctl boot "$UDID" 2>/dev/null || true

echo "== build protocol + agent =="
(cd reticle-swift && swift test >/dev/null)
"$ROOT/scripts/build-ios-agent.sh" >/dev/null
DYLIB="$ROOT/reticle-agent/ios/.build/arm64-apple-macosx/debug/libReticleInjection.dylib"

echo "== build + install sample apps =="
"$ROOT/scripts/build-sample-ios.sh" SampleApp        "$LINKED_ID"  "$UDID" >/dev/null
"$ROOT/scripts/build-sample-ios.sh" SampleAppNoAgent "$NOAGENT_ID" "$UDID" >/dev/null

hold_launch() { # bundleId [dylib port]
  xcrun simctl terminate "$UDID" "$1" 2>/dev/null || true
  sleep 1
  if [ -n "${2:-}" ]; then
    ( SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$2" SIMCTL_CHILD_RETICLE_PORT="$3" \
        xcrun simctl launch --console-pty "$UDID" "$1" >/dev/null 2>&1 ) & echo $!
  else
    ( xcrun simctl launch --console-pty "$UDID" "$1" >/dev/null 2>&1 ) & echo $!
  fi
}

# HID input (real synthesized touch/keyboard) works on every simulator runtime
# where the private SimulatorKit HID path initializes — verified on iOS 26.2 and
# 26.3. It is a capability, not a version cutoff, so HID steps run unconditionally
# and each asserts an observable side effect (below): a tap that merely "doesn't
# error" is worthless — the failure mode we guard against is a synthesized touch
# that sends cleanly yet never reaches a native control.

echo "== LINKED path =="
HOLD="$(hold_launch "$LINKED_ID")"; sleep 2
"$HOST" --target ios status --package "$LINKED_ID"
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/home"
"$HOST" --target ios ui compact "$TMP/home/snapshot.json"
# Navigate into the Checkout scenario: the home row is a SwiftUI NavigationLink
# (an axElement), driven by in-process activation — the path that also works on
# a real device and on runtimes below the HID-supported iOS 26.3, so scripted
# navigation never depends on HID.
"$HOST" --target ios act activate --package "$LINKED_ID" --test-id scenario.checkout
sleep 1
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/checkout"
"$HOST" --target ios ui compact "$TMP/checkout/snapshot.json"
"$HOST" --target ios ui screenshot --package "$LINKED_ID" --output "$TMP/shot.png"
# HID tap must LAND on a native control, not merely send without error. Tapping
# the Pay button flips checkout.status to "Paid!" — observable proof the
# synthesized touch reached UIKit. This is the regression guard for the silent
# no-op that shipped when the HID message shape drifted from the runtime (the
# tap sent fine and did nothing). Runs on every runtime; HID is a capability.
# `--trace-output` also exercises the iOS action-trace evidence package (the
# analogue of Android's traces): before/after snapshots + screenshots + a
# trace.json manifest whose diff records the observable change.
"$HOST" --target ios --serial "$UDID" act tap --package "$LINKED_ID" --test-id checkout.payButton --trace-output "$TMP/trace"
sleep 1
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/checkout-paid"
"$HOST" --target ios ui compact "$TMP/checkout-paid/snapshot.json" | grep -q "Paid!" \
  || { echo "FAIL: HID tap on payButton did not land (checkout.status never became Paid!)"; exit 1; }
TRACE_JSON="$(find "$TMP/trace" -name trace.json | head -1)"
[ -n "$TRACE_JSON" ] || { echo "FAIL: no action-trace manifest written under --trace-output"; exit 1; }
grep -q '"platform":"ios"' "$TRACE_JSON" || grep -q '"platform": "ios"' "$TRACE_JSON" \
  || { echo "FAIL: trace.json missing platform=ios"; exit 1; }
grep -q "Paid!" "$TRACE_JSON" \
  || { echo "FAIL: trace.json diff did not record the checkout.status change to Paid!"; exit 1; }
[ -f "$(dirname "$TRACE_JSON")/before.snapshot.json" ] && [ -f "$(dirname "$TRACE_JSON")/after.snapshot.json" ] \
  || { echo "FAIL: trace missing before/after snapshot artifacts"; exit 1; }
# `replay gif` stitches the recorded trace into the animated evidence artifact
# (host-local, no device). It must find the screenshots the trace just wrote.
"$HOST" replay gif "$TMP/trace"
[ -s "$TMP/trace/replay.gif" ] || { echo "FAIL: replay gif produced no artifact"; exit 1; }
"$HOST" --target ios mutate --package "$LINKED_ID" --test-id checkout.payButton --property alpha --value 0.4
kill "$HOLD" 2>/dev/null || true

echo "== AGREEMENT regions =="
export SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO=agreements
HOLD="$(hold_launch "$LINKED_ID")"; sleep 2
unset SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/agreements"
REGIONS="$("$HOST" --target ios ui regions "$TMP/agreements/snapshot.json")"
echo "$REGIONS"
echo "$REGIONS" | grep -q "span "       || { echo "FAIL: expected a span region (.link run)"; exit 1; }
echo "$REGIONS" | grep -q "textMarker"  || { echo "FAIL: expected textMarker regions (self-drawn row)"; exit 1; }
echo "$REGIONS" | grep -q "colorSpan"   || { echo "FAIL: expected a colorSpan region"; exit 1; }
# --region resolution must produce a tap point from a discovered region rect and
# from the char grid (plain phrase with no markers). Text regions have no
# in-process activation surface, so this is HID-only.
"$HOST" --target ios --serial "$UDID" act tap --package "$LINKED_ID" --test-id agreement.markdown --region "Privacy"
"$HOST" --target ios --serial "$UDID" act tap --package "$LINKED_ID" --test-id agreement.plain --region "Privacy Policy"
kill "$HOLD" 2>/dev/null || true

echo "== WEBVIEW DOM =="
export SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO=webview
HOLD="$(hold_launch "$LINKED_ID")"; sleep 3
unset SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/webview"
"$HOST" --target ios ui compact "$TMP/webview/snapshot.json" | grep -q "complex.title" \
  || { echo "FAIL: expected folded domNodes (complex.title) from the WKWebView"; exit 1; }
# CSS selector resolution: node lookup and a tap point from the dom frame.
# (#role-button sits above the fold regardless of fixture growth; below-fold
# elements are intentionally not captured.)
"$HOST" --target ios ui node "$TMP/webview/snapshot.json" --css "#role-button" >/dev/null \
  || { echo "FAIL: --css lookup on a folded domNode"; exit 1; }
# HID tap onto a folded DOM frame; the observable click below goes through DOM
# activation, which is HID-independent.
"$HOST" --target ios --serial "$UDID" act tap --package "$LINKED_ID" --css "#echo-name"
# Playwright-style piercing: an OPEN shadow root's content must fold in with a
# chained selector, and activation must resolve chains through shadow roots and
# same-origin iframes (works with no HID — the real-device path).
"$HOST" --target ios ui compact "$TMP/webview/snapshot.json" | grep -q "complex.shadowButton" \
  || { echo "FAIL: expected shadow DOM content (complex.shadowButton) folded in"; exit 1; }
"$HOST" --target ios act activate --package "$LINKED_ID" --css "#shadow-host >>> #shadow-button"
"$HOST" --target ios act activate --package "$LINKED_ID" --css "#fixture-frame >>> #iframe-button"
# In-process dom activation with an observable side effect.
"$HOST" --target ios act activate --package "$LINKED_ID" --css "#echo-name"
sleep 1
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/webview-after"
"$HOST" --target ios ui compact "$TMP/webview-after/snapshot.json" | grep -q "Echo: Ada" \
  || { echo "FAIL: dom activation did not fire #echo-name onclick"; exit 1; }
# Web evidence hooks: the report above installed them; the button logs to the
# console and fetches, and both must surface through /logs.
"$HOST" --target ios act activate --package "$LINKED_ID" --css "#web-evidence"
sleep 1
WEBLOGS="$("$HOST" --target ios debug logs --package "$LINKED_ID")"
echo "$WEBLOGS" | grep -q "web_console: evidence button clicked" \
  || { echo "FAIL: expected the web console event in /logs"; exit 1; }
echo "$WEBLOGS" | grep -q "web_network: GET data:text/plain,ok" \
  || { echo "FAIL: expected the web fetch event in /logs"; exit 1; }
kill "$HOLD" 2>/dev/null || true

echo "== TAB BAR (SwiftUI TabView) =="
export SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO=tabbar
HOLD="$(hold_launch "$LINKED_ID")"; sleep 2
unset SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/tabbar"
TABBAR="$("$HOST" --target ios ui compact "$TMP/tabbar/snapshot.json")"
for item in Home Orders Messages Profile; do
  echo "$TABBAR" | grep -q "control \"$item\"" \
    || { echo "FAIL: expected tab bar item \"$item\" (UITabBar view walk)"; exit 1; }
done
# The page content must fold in as axElements. Regression guard for the
# unlabeled-AX-container shape: a TabView page host (TabHostingController's
# hosting view) wraps its whole page in ONE unlabeled AX container, and a
# one-level element read used to filter it out and drop the page wholesale —
# content plainly on screen, invisible in the snapshot.
echo "$TABBAR" | grep -q "tabbar.status" \
  || { echo "FAIL: tab page SwiftUI content missing (unlabeled AX container regression)"; exit 1; }
echo "$TABBAR" | grep -q "Selected: home" \
  || { echo "FAIL: tabbar.status should read 'Selected: home' before any tap"; exit 1; }
# Tab buttons carry no testId (SwiftUI .tabItem cannot attach one), so resolve
# the Orders button's ref from the snapshot and HID-tap it. Observable side
# effect: the SwiftUI page swaps and tabbar.status flips to "Selected: orders".
ORDERS_REF="$(/usr/bin/python3 -c 'import json
s=json.load(open("'"$TMP"'/tabbar/snapshot.json"))
print(next(r for r,v in s["nodes"].items()
  if "Tab" in str(v.get("typeName","")) and "Button" in str(v.get("typeName",""))
  and v.get("contentDescription")=="Orders"))')"
"$HOST" --target ios --serial "$UDID" act tap --package "$LINKED_ID" --ref "$ORDERS_REF"
sleep 1
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/tabbar-orders"
"$HOST" --target ios ui compact "$TMP/tabbar-orders/snapshot.json" | grep -q "Selected: orders" \
  || { echo "FAIL: tapping the Orders tab did not update tabbar.status"; exit 1; }
kill "$HOLD" 2>/dev/null || true

echo "== LOGIN keyboard trap =="
# The stuck-login reproduction: a bottom submit button the keyboard covers.
# Reticle must (1) report the keyboard in the snapshot, (2) mark the covered
# button occluded-by:keyboard, (3) dismiss it with hide-keyboard, and (4) the
# button must then be actionable.
export SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO=login
HOLD="$(hold_launch "$LINKED_ID")"; sleep 2
unset SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO
# Focus the code field with a HID tap so the system keyboard actually comes up.
"$HOST" --target ios --serial "$UDID" act tap --package "$LINKED_ID" --test-id login.codeField
sleep 1
# type must report the keyboard it left behind.
TYPE_OUT="$("$HOST" --target ios --serial "$UDID" act type --package "$LINKED_ID" --text "123456")"
echo "$TYPE_OUT"
echo "$TYPE_OUT" | grep -Eq "keyboardVisible=(1|true)" \
  || { echo "FAIL: act type did not report the keyboard. If the software keyboard never appeared, disable Simulator's 'Connect Hardware Keyboard' (I/O > Keyboard) and reboot the sim device."; exit 1; }
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/login"
LOGIN_COMPACT="$("$HOST" --target ios ui compact "$TMP/login/snapshot.json")"
echo "$LOGIN_COMPACT"
echo "$LOGIN_COMPACT" | grep -q "keyboard: visible" \
  || { echo "FAIL: compact must lead with 'keyboard: visible' while the keyboard is up"; exit 1; }
echo "$LOGIN_COMPACT" | grep "login.submitButton" | grep -q "occluded-by:keyboard" \
  || { echo "FAIL: the covered submit button must be marked occluded-by:keyboard"; exit 1; }
# Dismiss in-process and confirm the settled state round-trips.
HIDE_OUT="$("$HOST" --target ios act hide-keyboard --package "$LINKED_ID")"
echo "$HIDE_OUT"
echo "$HIDE_OUT" | grep -Eq "wasVisible=(1|true)" \
  || { echo "FAIL: hide-keyboard must report wasVisible"; exit 1; }
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/login-hidden"
LOGIN_AFTER="$("$HOST" --target ios ui compact "$TMP/login-hidden/snapshot.json")"
echo "$LOGIN_AFTER" | grep -q "keyboard: hidden" \
  || { echo "FAIL: compact must report 'keyboard: hidden' after hide-keyboard"; exit 1; }
echo "$LOGIN_AFTER" | grep "login.submitButton" | grep -q "occluded-by" \
  && { echo "FAIL: submit button still occluded after hide-keyboard"; exit 1; }
# The freed button must now actually work: activate it and observe the status flip.
"$HOST" --target ios act activate --package "$LINKED_ID" --test-id login.submitButton
sleep 1
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/login-done"
"$HOST" --target ios ui compact "$TMP/login-done/snapshot.json" | grep -q "Logged in: 123456" \
  || { echo "FAIL: submit after hide-keyboard did not log in"; exit 1; }
kill "$HOLD" 2>/dev/null || true

echo "== INJECTION path (noagent app) =="
PORT="$(/usr/bin/python3 -c 'x=0x811C9DC5
for b in "'"$NOAGENT_ID"'".encode(): x^=b; x=(x*0x01000193)&0xFFFFFFFF
print(8765+(x%1000))')"
HOLD="$(hold_launch "$NOAGENT_ID" "$DYLIB" "$PORT")"; sleep 3
"$HOST" --target ios ui report --package "$NOAGENT_ID" --output "$TMP/inject"
"$HOST" --target ios ui compact "$TMP/inject/snapshot.json"
kill "$HOLD" 2>/dev/null || true

echo "== OK: artifacts in $TMP =="
