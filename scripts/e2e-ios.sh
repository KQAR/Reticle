#!/usr/bin/env bash
# End-to-end smoke test for the iOS agent on a simulator. Builds the shared
# protocol, the in-process agent, the sample apps, installs them, and exercises
# the full round trip through `reticle --target ios`: linked launch + inject,
# ui report, compact, screenshot, a mutate, an `act --verify` node-state diff,
# the system dialog (UIAlertController content recognition), the native Lottie
# dialog, the web Lottie modal, the web-component (shadow DOM) modal, and the
# Lottie-only dialog (recovering elements baked into one Lottie).
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

echo "== LONG LIST (lazy boundary + scroll evidence) =="
# SwiftUI's List realizes only the rows near the viewport, so a far-down row has
# no view, no accessibility element, and no frame: the selector is absent, not
# off-screen. Reticle reports the scroll view's remaining travel so an agent can
# tell "not realized yet" from "this app has no such element".
export SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO=list
HOLD="$(hold_launch "$LINKED_ID")"; sleep 2
unset SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/list"
LIST_COMPACT="$("$HOST" --target ios ui compact "$TMP/list/snapshot.json")"
echo "$LIST_COMPACT"
echo "$LIST_COMPACT" | grep -q "scrollView.*scroll:down" \
  || { echo "FAIL: the List's scroll view must report it can still scroll down"; exit 1; }
/usr/bin/python3 - "$TMP/list/snapshot.json" <<'PY' || exit 1
import json, re, sys
nodes = json.load(open(sys.argv[1]))["nodes"].values()
rows = sorted(int(re.sub(r"\D", "", n["testId"]))
              for n in nodes if (n.get("testId") or "").startswith("list.item"))
if not rows or rows[0] != 0:
    print(f"FAIL: expected the first rows to be realized, got {rows}"); sys.exit(1)
if 40 in rows:
    print("FAIL: row 40 should NOT be realized yet — the lazy boundary is what this asserts")
    sys.exit(1)
PY
MISS="$("$HOST" --target ios --serial "$UDID" act tap --package "$LINKED_ID" --test-id list.item40 2>&1 || true)"
echo "$MISS" | grep -q "scrollable content" \
  || { echo "FAIL: a miss on an unrealized row must mention the scrollable container: $MISS"; exit 1; }
# `act scroll-to` drags the container until the selector resolves INSIDE it, then
# polls until the position stops moving before reporting it. The settle step is
# the contract: a flinging list keeps moving after the gesture returns, and a
# point reported mid-fling is already stale for the next command.
SCROLLED="$("$HOST" --target ios --serial "$UDID" act scroll-to --package "$LINKED_ID" --test-id list.item40)"
echo "$SCROLLED"
echo "$SCROLLED" | grep -q "found=true" \
  || { echo "FAIL: scroll-to did not bring list.item40 into view"; exit 1; }
echo "$SCROLLED" | grep -q "settled=true" \
  || { echo "FAIL: scroll-to reported a position it could not confirm had stopped moving"; exit 1; }
"$HOST" --target ios --serial "$UDID" act tap --package "$LINKED_ID" --test-id list.item40
sleep 1
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/list-40"
"$HOST" --target ios ui compact "$TMP/list-40/snapshot.json" | grep -q "Picked row 40" \
  || { echo "FAIL: the point scroll-to reported was not usable by the next tap"; exit 1; }
# A selector nothing in the list can satisfy must fail LOUDLY, saying the
# container ran out of travel rather than implying it might still appear.
NOPE="$("$HOST" --target ios --serial "$UDID" act scroll-to --package "$LINKED_ID" --test-id list.item999 2>&1 || true)"
echo "$NOPE" | grep -qE "reached the end|gave up after" \
  || { echo "FAIL: scroll-to must report exhaustion for an absent row: $NOPE"; exit 1; }
kill "$HOLD" 2>/dev/null || true

echo "== CANVAS CONTROL regions (accessibility sub-elements) =="
# Two self-drawn controls, one per legal `UIAccessibilityContainer` convention:
# `accessibilityElements` (the shorthand) and the container METHODS
# (`accessibilityElementCount` / `accessibilityElement(at:)`, elements built on
# demand). The probe originally read only the array, so every control written the
# second way surfaced zero sub-regions. There is no touch-delegate analogue on
# iOS: an expanded hit area is a `point(inside:with:)` override, i.e. app code
# with no introspectable rect.
export SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO=canvasControl
HOLD="$(hold_launch "$LINKED_ID")"; sleep 2
unset SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/canvas"
CANVAS_REGIONS="$("$HOST" --target ios ui regions "$TMP/canvas/snapshot.json")"
echo "$CANVAS_REGIONS"
echo "$CANVAS_REGIONS" | grep -q 'a11yVirtual "Monthly"' \
  || { echo "FAIL: expected sub-regions from the accessibilityElements control"; exit 1; }
echo "$CANVAS_REGIONS" | grep -q 'a11yVirtual "A3"' \
  || { echo "FAIL: expected sub-regions from the CONTAINER-METHODS control"; exit 1; }
# The segments are painted, not subviews, and the control hit-tests taps itself,
# so only a correct recovered rect produces the status change. HID-only (a
# painted segment has no in-process activation surface).
"$HOST" --target ios --serial "$UDID" act tap --package "$LINKED_ID" --test-id canvas.segments --region "Monthly"
sleep 1
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/canvas-seg"
"$HOST" --target ios ui compact "$TMP/canvas-seg/snapshot.json" | grep -q "Segment: Monthly" \
  || { echo "FAIL: tap on the accessibilityElements sub-region did not land"; exit 1; }
"$HOST" --target ios --serial "$UDID" act tap --package "$LINKED_ID" --test-id canvas.seats --region "A3"
sleep 1
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/canvas-seat"
"$HOST" --target ios ui compact "$TMP/canvas-seat/snapshot.json" | grep -q "Seat: A3" \
  || { echo "FAIL: tap on the container-methods sub-region did not land"; exit 1; }
CANVAS_LOGS="$("$HOST" --target ios debug logs --package "$LINKED_ID")"
echo "$CANVAS_LOGS" | grep -q "canvas_seat_picked" \
  || { echo "FAIL: expected canvas_seat_picked in the app log bridge"; exit 1; }
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
# Same-origin iframe GEOMETRY, not just chain resolution: frame content
# coordinates are relative to the frame viewport, so the walk accumulates the
# frame's page offset. Dropping it is silent — the rect lands near the top of the
# page. Assert the inner rect is inside the frame's, then prove it with a HID tap
# (activation above would pass even with a wrong rect).
/usr/bin/python3 - "$TMP/webview/snapshot.json" <<'PY' || exit 1
import json, sys
nodes = json.load(open(sys.argv[1]))["nodes"].values()
frame = next(n["frame"] for n in nodes if n.get("testId") == "complex.iframe")
button = next(n["frame"] for n in nodes if n.get("testId") == "complex.iframeButton")
inside = (button["x"] >= frame["x"] - 1 and button["y"] >= frame["y"] - 1
          and button["x"] + button["width"] <= frame["x"] + frame["width"] + 1
          and button["y"] + button["height"] <= frame["y"] + frame["height"] + 1)
if not inside:
    print(f"FAIL: iframe content rect {button} is not inside the frame rect {frame}")
    sys.exit(1)
PY
"$HOST" --target ios --serial "$UDID" act tap --package "$LINKED_ID" --css "#fixture-frame >>> #iframe-button"
sleep 1
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/webview-frame"
"$HOST" --target ios ui compact "$TMP/webview-frame/snapshot.json" | grep -q "Frame clicked" \
  || { echo "FAIL: coordinate tap at the iframe content rect did not fire its onclick"; exit 1; }
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
# The freed button must now actually work: activate it with --verify watching the
# status node, and confirm iOS reports the login-status text flip as a diff (the
# iOS analogue of the Android helper's --verify; iOS previously dropped it).
LOGIN_OUT="$("$HOST" --target ios act activate --package "$LINKED_ID" --test-id login.submitButton --verify '#login.status')"
echo "$LOGIN_OUT"
echo "$LOGIN_OUT" | grep -Eq "verify #login.status: changed" \
  || { echo "FAIL: iOS --verify did not report the login.status change"; exit 1; }
echo "$LOGIN_OUT" | grep -q "Logged in: 123456" \
  || { echo "FAIL: iOS --verify diff did not capture the 'Logged in: 123456' status text"; exit 1; }
sleep 1
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/login-done"
"$HOST" --target ios ui compact "$TMP/login-done/snapshot.json" | grep -q "Logged in: 123456" \
  || { echo "FAIL: submit after hide-keyboard did not log in"; exit 1; }
kill "$HOLD" 2>/dev/null || true

echo "== SYSTEM DIALOG (UIAlertController) =="
# A UIAlertController raised over the scenario. Unlike Android's AlertDialog
# (a distinct WindowManagerGlobal root), iOS presents the alert *inside* the
# presenting window's hierarchy, so this asserts the capture surfaces the alert's
# own content — title / message / actions — rather than window-vs-window
# occlusion (there is no separate dialog window to occlude the background here,
# which is why, deliberately, there is no occluded-by assertion on iOS).
export SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO=dialog
HOLD="$(hold_launch "$LINKED_ID")"; sleep 2
unset SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO
# Raise the alert. The trigger is a UIButton, so in-process activation works
# (no HID needed) — the same path that works on a real device.
"$HOST" --target ios act activate --package "$LINKED_ID" --test-id dialog.trigger
sleep 1
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/dialog"
DIALOG_COMPACT="$("$HOST" --target ios ui compact "$TMP/dialog/snapshot.json")"
echo "$DIALOG_COMPACT"
echo "$DIALOG_COMPACT" | grep -q "Delete account?" \
  || { echo "FAIL: alert title 'Delete account?' not captured"; exit 1; }
echo "$DIALOG_COMPACT" | grep -q "This action cannot be undone." \
  || { echo "FAIL: alert message not captured"; exit 1; }
echo "$DIALOG_COMPACT" | grep -q '"Delete"' \
  || { echo "FAIL: alert 'Delete' action not captured"; exit 1; }
echo "$DIALOG_COMPACT" | grep -q '"Cancel"' \
  || { echo "FAIL: alert 'Cancel' action not captured"; exit 1; }
# Alert actions carry no testId (UIAlertAction cannot attach one), which is exactly
# what `--label` is for: match the visible text, refuse ambiguity, and never fall
# back to guessing. This replaced a snapshot-scraping hack that dug the ref out
# with python — refs are minted per capture, so that was fragile by construction.
"$HOST" --target ios --serial "$UDID" act tap --package "$LINKED_ID" --label "Delete"
sleep 1
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/dialog-done"
DIALOG_AFTER="$("$HOST" --target ios ui compact "$TMP/dialog-done/snapshot.json")"
echo "$DIALOG_AFTER" | grep -q "Deleted" \
  || { echo "FAIL: HID tap on 'Delete' did not land (dialog.status never became Deleted)"; exit 1; }
echo "$DIALOG_AFTER" | grep -q "Delete account?" \
  && { echo "FAIL: alert still present after tapping Delete (it should be dismissed)"; exit 1; }
# App-authored log bridge: the dialog logs must surface through /logs.
DIALOG_LOGS="$("$HOST" --target ios debug logs --package "$LINKED_ID")"
echo "$DIALOG_LOGS" | grep -q "dialog_opened" \
  || { echo "FAIL: expected dialog_opened in the app log bridge"; exit 1; }
echo "$DIALOG_LOGS" | grep -q "dialog_confirmed" \
  || { echo "FAIL: expected dialog_confirmed in the app log bridge"; exit 1; }
kill "$HOLD" 2>/dev/null || true

echo "== LOTTIE DIALOG (native, with a real Lottie animation view) =="
# A custom modal card whose content includes a real Lottie animation view. The
# animation is opaque (no text); this asserts the recognizable elements around it
# — title, message, button — are captured with correct content, and that the
# Lottie view itself is located as a node with a frame.
export SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO=lottieDialog
HOLD="$(hold_launch "$LINKED_ID")"; sleep 2
unset SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO
"$HOST" --target ios act activate --package "$LINKED_ID" --test-id lottieDialog.trigger
sleep 1
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/lottie"
LOTTIE_COMPACT="$("$HOST" --target ios ui compact "$TMP/lottie/snapshot.json")"
echo "$LOTTIE_COMPACT"
echo "$LOTTIE_COMPACT" | grep -q "Please wait" \
  || { echo "FAIL: lottie dialog title 'Please wait' not captured"; exit 1; }
echo "$LOTTIE_COMPACT" | grep -q "Processing your request." \
  || { echo "FAIL: lottie dialog message not captured"; exit 1; }
echo "$LOTTIE_COMPACT" | grep -q "lottieDialog.animation" \
  || { echo "FAIL: the Lottie animation view must be located as a node with a frame"; exit 1; }
echo "$LOTTIE_COMPACT" | grep "lottieDialog.done" | grep -q 'button' \
  || { echo "FAIL: lottie dialog 'Done' button not captured"; exit 1; }
# The button must land: Done dismisses and flips lottieDialog.status to "Done".
"$HOST" --target ios --serial "$UDID" act tap --package "$LINKED_ID" --test-id lottieDialog.done
sleep 1
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/lottie-done"
"$HOST" --target ios ui compact "$TMP/lottie-done/snapshot.json" | grep "lottieDialog.status" | grep -q "Done" \
  || { echo "FAIL: tapping Done did not flip lottieDialog.status to Done"; exit 1; }
"$HOST" --target ios debug logs --package "$LINKED_ID" | grep -q "lottie_dialog_confirmed" \
  || { echo "FAIL: expected lottie_dialog_confirmed in the app log bridge"; exit 1; }
kill "$HOLD" 2>/dev/null || true

echo "== WEB LOTTIE DIALOG (lottie-web modal inside a WKWebView) =="
# A modal rendered in the WKWebView by lottie-web. Asserts the DOM bridge folds
# the modal's elements (dialog role, animation container, title, message, button)
# into the unified tree with content + frames while an animated <svg> plays.
export SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO=webLottieDialog
HOLD="$(hold_launch "$LINKED_ID")"; sleep 3
unset SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO
"$HOST" --target ios act activate --package "$LINKED_ID" --css "#open-lottie"
sleep 2
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/web-lottie"
WEB_LOTTIE="$("$HOST" --target ios ui compact "$TMP/web-lottie/snapshot.json")"
echo "$WEB_LOTTIE"
echo "$WEB_LOTTIE" | grep "webLottie.dialog" | grep -q "dialog" \
  || { echo "FAIL: web lottie modal (role=dialog) not folded in"; exit 1; }
echo "$WEB_LOTTIE" | grep -q "webLottie.animation" \
  || { echo "FAIL: lottie-web animation container not captured"; exit 1; }
echo "$WEB_LOTTIE" | grep "webLottie.title" | grep -q "Please wait" \
  || { echo "FAIL: web lottie title not captured"; exit 1; }
echo "$WEB_LOTTIE" | grep "webLottie.message" | grep -q "Processing your request." \
  || { echo "FAIL: web lottie message not captured"; exit 1; }
echo "$WEB_LOTTIE" | grep "webLottie.done" | grep -q 'button' \
  || { echo "FAIL: web lottie 'Done' button not captured"; exit 1; }
# The DOM button must land: #lottie-done sets #web-status to "Done".
"$HOST" --target ios act activate --package "$LINKED_ID" --css "#lottie-done"
sleep 1
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/web-lottie-done"
"$HOST" --target ios ui compact "$TMP/web-lottie-done/snapshot.json" | grep "webLottie.status" | grep -q "Done" \
  || { echo "FAIL: tapping the web lottie 'Done' button did not update the status"; exit 1; }
kill "$HOLD" 2>/dev/null || true

echo "== WEB COMPONENT DIALOG (custom element + open shadow root) =="
# A modal built as a Web Component whose content lives in an OPEN shadow root.
# Asserts Reticle pierces the shadow boundary and folds the modal's elements into
# the unified tree with content + frames, and that a shadow-piercing activate lands.
export SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO=webComponentDialog
HOLD="$(hold_launch "$LINKED_ID")"; sleep 3
unset SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO
"$HOST" --target ios act activate --package "$LINKED_ID" --css "#open-wc"
sleep 1
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/web-comp"
WEB_COMP="$("$HOST" --target ios ui compact "$TMP/web-comp/snapshot.json")"
echo "$WEB_COMP"
echo "$WEB_COMP" | grep "webComponent.title" | grep -q "Delete item?" \
  || { echo "FAIL: shadow-DOM title not folded in (shadow piercing)"; exit 1; }
echo "$WEB_COMP" | grep "webComponent.message" | grep -q "remove it permanently." \
  || { echo "FAIL: shadow-DOM message not folded in"; exit 1; }
echo "$WEB_COMP" | grep "webComponent.cancel" | grep -q 'button "Cancel"' \
  || { echo "FAIL: shadow-DOM Cancel button not folded in"; exit 1; }
echo "$WEB_COMP" | grep "webComponent.confirm" | grep -q 'button "Delete"' \
  || { echo "FAIL: shadow-DOM Delete button not folded in"; exit 1; }
# A shadow-piercing activate must land: #wc-confirm sets #wc-status to "Deleted".
"$HOST" --target ios act activate --package "$LINKED_ID" --css "confirm-dialog >>> #wc-confirm"
sleep 1
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/web-comp-done"
"$HOST" --target ios ui compact "$TMP/web-comp-done/snapshot.json" | grep "webComponent.status" | grep -q "Deleted" \
  || { echo "FAIL: shadow-piercing activate on Delete did not update the status"; exit 1; }
kill "$HOLD" 2>/dev/null || true

echo "== LOTTIE-ONLY DIALOG (whole dialog baked into one Lottie) =="
# The title / message / both buttons are Lottie layers, not views. The Lottie
# bridge (Mirror-reflects the parsed model) surfaces each text layer as a
# `lottie` region (content + screen rect). Asserts those elements are recovered
# and that an HID tap at a recovered position fires the app's in-canvas hit-test
# callback (there are no child views to activate).
export SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO=lottieOnlyDialog
HOLD="$(hold_launch "$LINKED_ID")"; sleep 2
unset SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO
"$HOST" --target ios act activate --package "$LINKED_ID" --test-id lottieOnly.trigger
sleep 1
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/lottie-only"
LOTTIE_REGIONS="$("$HOST" --target ios ui regions "$TMP/lottie-only/snapshot.json")"
echo "$LOTTIE_REGIONS"
echo "$LOTTIE_REGIONS" | grep -q 'lottie "Delete item?"' \
  || { echo "FAIL: Lottie title not recovered from the model"; exit 1; }
echo "$LOTTIE_REGIONS" | grep -q 'lottie "This will remove it permanently."' \
  || { echo "FAIL: Lottie message not recovered"; exit 1; }
echo "$LOTTIE_REGIONS" | grep -q 'lottie "Cancel"' \
  || { echo "FAIL: Lottie Cancel button not recovered"; exit 1; }
echo "$LOTTIE_REGIONS" | grep -q 'lottie "Delete"' \
  || { echo "FAIL: Lottie Delete button not recovered"; exit 1; }
# Tap the *recovered* Delete position and confirm the in-canvas callback fires.
DELETE_PT="$(/usr/bin/python3 -c 'import json,sys
s=json.load(open(sys.argv[1]))
for v in s["nodes"].values():
    for g in (v.get("regions") or []):
        if g.get("source")=="lottie" and g.get("label")=="Delete":
            r=g["rects"][0]; print("%d,%d" % (int(r["x"]+r["width"]/2), int(r["y"]+r["height"]/2))); sys.exit(0)' \
  "$TMP/lottie-only/snapshot.json")"
[ -n "$DELETE_PT" ] || { echo "FAIL: could not resolve the recovered Delete region point"; exit 1; }
"$HOST" --target ios --serial "$UDID" act tap --package "$LINKED_ID" --point "$DELETE_PT"
sleep 1
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/lottie-only-done"
"$HOST" --target ios ui compact "$TMP/lottie-only-done/snapshot.json" | grep "lottieOnly.status" | grep -q "Deleted" \
  || { echo "FAIL: tapping the recovered Lottie 'Delete' position did not fire the in-canvas callback"; exit 1; }
"$HOST" --target ios debug logs --package "$LINKED_ID" | grep -q "lottie_only_choice" \
  || { echo "FAIL: expected lottie_only_choice in the app log bridge"; exit 1; }
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
