#!/usr/bin/env bash
# End-to-end smoke test for the iOS agent on a simulator. Builds the shared
# protocol, the in-process agent, the sample apps, installs them, and exercises
# the full round trip through `reticle --target ios`: linked launch + inject,
# ui report, compact, screenshot, a mutate, an `act --verify` node-state diff,
# the wheel picker (a UIPickerView's rows ARE nodes, unlike Android's — and the
# CGRectInfinite frames its scroll indicators carry),
# the system dialog (UIAlertController content recognition), the native Lottie
# dialog, the web Lottie modal, the web-component (shadow DOM) modal, the
# Lottie-only dialog (recovering elements baked into one Lottie), and — last, for
# the reasons stated there — the system permission prompt (an out-of-process window
# -> `window: UNFOCUSED`, asserted both while it is up and once it is answered).
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
# Keep the linked app's bundle path: the permission section reinstalls it to re-arm
# the notification prompt (see the last section for why).
LINKED_APP="$("$ROOT/scripts/build-sample-ios.sh" SampleApp "$LINKED_ID" "$UDID" | tail -1)"
LINKED_APP="${LINKED_APP#APP_BUNDLE=}"
[ -d "$LINKED_APP" ] || { echo "FAIL: build-sample-ios.sh did not report the .app bundle path"; exit 1; }
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
# Style evidence. Two things are asserted because both were silent when wrong:
# UIKit lengths are POINTS, already density-independent, so the projection must
# NOT print a dp figure for them (dividing by `density` again would halve every
# length while looking perfectly plausible); and `fontScale` must be probed, or a
# text size cannot be split into "wrong size" and "user enlarged text".
STYLE="$("$HOST" --target ios ui style "$TMP/checkout/snapshot.json")"
echo "$STYLE" | head -20
echo "$STYLE" | grep -q "pt density=" \
  || { echo "FAIL: expected the screen line to report points, not px, on iOS"; exit 1; }
echo "$STYLE" | grep -q "fontScale=[0-9]" \
  || { echo "FAIL: expected a probed fontScale on iOS (got 'unprobed')"; exit 1; }
echo "$STYLE" | grep -q "textSize .*pt" \
  || { echo "FAIL: expected a textSize in points from a UILabel"; exit 1; }
echo "$STYLE" | grep -qE "^ +frame .*pt \| [0-9.]+%x" \
  || { echo "FAIL: a frame must render as points + a share of the screen, never pt->dp"; exit 1; }
echo "$STYLE" | grep -q "dp" \
  && { echo "FAIL: an iOS length was converted to dp — points are already density-independent"; exit 1; }
echo "$STYLE" | grep -q "\[viewField\]" \
  || { echo "FAIL: expected style values to carry their channel"; exit 1; }
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
echo "== WAIT: three-state outcome (resolved / absent) + --strict exit codes =="
# The iOS half of `act wait`. It dispatches no input, so unlike `tap` it needs no
# HID surface and works on real devices too. The classification comes from
# ReticleProtocol — the same code the Android helper runs, pinned by
# reticle-protocol/fixtures/wait-classification.cases.json — so what this proves
# is that the iOS poll loop feeds it the right probe.
#
# checkout.status is "Paid!" by now, so a matching text predicate holds.
WAIT_OK="$("$HOST" --target ios act wait --package "$LINKED_ID" --for '#checkout.status' --text 'Paid' --timeout 4000)"
echo "$WAIT_OK"
echo "$WAIT_OK" | grep -q "RESOLVED" \
  || { echo "FAIL: wait on the already-flipped checkout.status was not RESOLVED"; exit 1; }
echo "$WAIT_OK" | grep -q 'text testId=checkout.status contains "Paid"' \
  || { echo "FAIL: wait did not echo the predicate it was given"; exit 1; }
# A miss on a node that DOES resolve, on a settled screen: an honest negative that
# reports what was actually there.
WAIT_ABSENT="$("$HOST" --target ios act wait --package "$LINKED_ID" --for '#checkout.status' --text 'NeverGonnaHappen' --timeout 3000)"
echo "$WAIT_ABSENT"
echo "$WAIT_ABSENT" | grep -q "ABSENT" \
  || { echo "FAIL: a settled miss on a resolved node must be ABSENT, not unknowable"; exit 1; }
echo "$WAIT_ABSENT" | grep -q 'observed: "Paid!"' \
  || { echo "FAIL: an absent text predicate must report the text it DID find"; exit 1; }
# A timeout is an observation, not a tool failure: ok stays true, exit stays 0.
"$HOST" --target ios act wait --package "$LINKED_ID" --for '#checkout.status' --text 'NeverGonnaHappen' \
  --timeout 1500 --json | grep -q '"ok":true' \
  || { echo "FAIL: a timed-out wait must still be ok:true in the JSON envelope"; exit 1; }
# --strict projects the outcome onto an exit code. 3 (not there) and 4 (could not
# see) must stay distinct — the unknowable side is asserted in the permission
# section below.
set +e
"$HOST" --target ios act wait --package "$LINKED_ID" --for '#checkout.status' --text 'Paid' --timeout 3000 --strict >/dev/null
WAIT_RC_OK=$?
"$HOST" --target ios act wait --package "$LINKED_ID" --for '#checkout.status' --text 'NeverGonnaHappen' --timeout 1500 --strict >/dev/null
WAIT_RC_ABSENT=$?
set -e
[ "$WAIT_RC_OK" -eq 0 ] || { echo "FAIL: --strict on a resolved wait exited $WAIT_RC_OK, expected 0"; exit 1; }
[ "$WAIT_RC_ABSENT" -eq 3 ] || { echo "FAIL: --strict on an absent wait exited $WAIT_RC_ABSENT, expected 3"; exit 1; }
# `gone` on a selector that never existed holds immediately.
"$HOST" --target ios act wait --package "$LINKED_ID" --for '#no.such.node.anywhere' --gone --timeout 2000 \
  | grep -q "RESOLVED" \
  || { echo "FAIL: gone on a nonexistent selector was not RESOLVED"; exit 1; }
# `--idle` states no expectation about content, so it can never report `absent`,
# and must return once the screen is quiet rather than at the deadline.
WAIT_IDLE="$("$HOST" --target ios act wait --package "$LINKED_ID" --idle --timeout 20000)"
echo "$WAIT_IDLE"
echo "$WAIT_IDLE" | grep -q "idle: RESOLVED" \
  || { echo "FAIL: --idle did not settle on a static screen"; exit 1; }
IDLE_MS="$(printf '%s' "$WAIT_IDLE" | sed -n 's/.*RESOLVED in \([0-9]*\)ms.*/\1/p')"
[ -n "$IDLE_MS" ] && [ "$IDLE_MS" -lt 5000 ] \
  || { echo "FAIL: --idle took ${IDLE_MS:-?}ms on a static screen; it must return once quiet"; exit 1; }
# Both platforms must refuse the same unanswerable predicates, word for word.
set +e
"$HOST" --target ios act wait --package "$LINKED_ID" --point 10,20 --timeout 1000 >/dev/null 2>"$TMP/wait-point.err"
WAIT_RC_POINT=$?
set -e
[ "$WAIT_RC_POINT" -ne 0 ] || { echo "FAIL: wait --point must be refused (a coordinate always resolves)"; exit 1; }
grep -q -- "--point" "$TMP/wait-point.err" \
  || { echo "FAIL: the --point refusal must say why; got: $(cat "$TMP/wait-point.err")"; exit 1; }

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

echo "== SWIFTUI TEXT LINKS (two links inside ONE Text) =="
# The SwiftUI shape of the agreement row, and the asymmetry this closes: a markdown
# `Text` is ONE accessibility element with one label — no UILabel, no
# NSAttributedString .link run, no child element, no view to measure — so every
# RegionProbe channel came up empty and the links were unaddressable, while the
# UIKit row above decomposes fine. (The Android twin was fixed for Compose in the
# same sweep.) The surface that does exist is `accessibilityAttributedLabel`:
# system-emitted `UIAccessibilityTokenLink` runs plus per-run font tokens, from
# which the geometry is re-laid out inside the element's own screen frame.
# Each assertion is an OBSERVABLE side effect: the app's openURL handler names the
# link it received, so a rect that is merely plausible fails here.
export SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO=swiftui
HOLD="$(hold_launch "$LINKED_ID")"; sleep 2
unset SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/swiftui"
SWIFTUI_REGIONS="$("$HOST" --target ios ui regions "$TMP/swiftui/snapshot.json")"
echo "$SWIFTUI_REGIONS"
echo "$SWIFTUI_REGIONS" | grep -q 'span "Terms"' \
  || { echo "FAIL: the 'Terms' link inside the SwiftUI Text was not recovered"; exit 1; }
echo "$SWIFTUI_REGIONS" | grep -q 'span "Privacy"' \
  || { echo "FAIL: the 'Privacy' link inside the SwiftUI Text was not recovered"; exit 1; }
"$HOST" --target ios --serial "$UDID" act tap --package "$LINKED_ID" --test-id swiftui.agreement --region "Privacy"
sleep 1
"$HOST" --target ios ui compact --live --package "$LINKED_ID" | grep "swiftui.status" | grep -q "opened privacy" \
  || { echo "FAIL: tapping the recovered 'Privacy' rect did not open the privacy link"; exit 1; }
# The other link must be its own target, not the same rect: tapping "Terms" opens
# terms. Two links in one node are worth nothing if they resolve to one point.
"$HOST" --target ios --serial "$UDID" act tap --package "$LINKED_ID" --test-id swiftui.agreement --region "Terms"
sleep 1
"$HOST" --target ios ui compact --live --package "$LINKED_ID" | grep "swiftui.status" | grep -q "opened terms" \
  || { echo "FAIL: tapping the recovered 'Terms' rect did not open the terms link"; exit 1; }
"$HOST" --target ios debug logs --package "$LINKED_ID" | grep -q "swiftui_link_clicked" \
  || { echo "FAIL: expected swiftui_link_clicked in the app log bridge"; exit 1; }
# The char grid rides along, so a phrase that is NOT a link is addressable too.
"$HOST" --target ios --serial "$UDID" act tap --package "$LINKED_ID" --test-id swiftui.agreement --region "Read the" \
  || { echo "FAIL: the reconstructed char grid must resolve a non-link substring"; exit 1; }
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
# The same evidence must lift a `wait` out of `absent`. An unrealized row has no
# node at all, so reporting `absent` would tell an agent the app lacks a feature
# it simply had not scrolled to.
WAIT_UNKNOWABLE="$("$HOST" --target ios act wait --package "$LINKED_ID" --for '#list.item40' --timeout 3000)"
echo "$WAIT_UNKNOWABLE"
echo "$WAIT_UNKNOWABLE" | grep -q "UNKNOWABLE" \
  || { echo "FAIL: a wait for an unrealized row must be UNKNOWABLE, never ABSENT"; exit 1; }
echo "$WAIT_UNKNOWABLE" | grep -q "scroll:" \
  || { echo "FAIL: the unknowable verdict must name the scroll travel that clouds it"; exit 1; }
echo "$WAIT_UNKNOWABLE" | grep -q "next: act scroll-to --test-id list.item40" \
  || { echo "FAIL: the unknowable verdict must suggest scroll-to for the row"; exit 1; }
set +e
"$HOST" --target ios act wait --package "$LINKED_ID" --for '#list.item40' --timeout 1500 --strict >/dev/null
WAIT_RC_UNKNOWABLE=$?
set -e
[ "$WAIT_RC_UNKNOWABLE" -eq 4 ] \
  || { echo "FAIL: --strict on an unknowable wait exited $WAIT_RC_UNKNOWABLE, expected 4 (not 3)"; exit 1; }
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

echo "== WHEEL PICKER (the asymmetric twin of Android's) =="
# The one scenario that measures a DIFFERENCE between the platforms rather than
# parity. Android's `NumberPicker` paints its unselected values onto the wheel
# canvas, so only the selection is a node. `UIPickerView` builds a real subview
# per visible row, so its neighbours ARE nodes and a label tap on one selects it;
# on top of that the picker exposes each component's current value as an
# `a11yVirtual` region, so "which wheel is on what" is readable without parsing
# rows. Both facts are asserted here, because losing either would make the iOS
# side silently as blind as the Android one.
export SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO=wheelPicker
HOLD="$(hold_launch "$LINKED_ID")"; sleep 2
unset SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/wheel"
WHEEL_COMPACT="$("$HOST" --target ios ui compact "$TMP/wheel/snapshot.json")"
echo "$WHEEL_COMPACT"
# The selection of each component, as a region on the picker node itself.
WHEEL_REGIONS="$("$HOST" --target ios ui regions "$TMP/wheel/snapshot.json")"
echo "$WHEEL_REGIONS" | grep -q 'a11yVirtual "09"' \
  || { echo "FAIL: the picker must expose each component's value as a region, got: $WHEEL_REGIONS"; exit 1; }
# A `UIPickerView`'s hidden scroll indicators carry CGRectInfinite as their frame.
# Those components are FINITE doubles (~1.8e308), so an `isFinite` guard waves
# them through while `Int(_:)` traps on them — formatting one used to abort the
# whole host with SIGTRAP while writing an action trace. The capture now drops a
# frame it cannot represent, which is why this assertion is here and not a unit
# test: the sentinel only exists on a real UIKit view.
/usr/bin/python3 - "$TMP/wheel/snapshot.json" <<'PY' || exit 1
import json, sys
nodes = json.load(open(sys.argv[1]))["nodes"].values()
bad = [(n.get("ref"), n.get("typeName"), n["frame"]) for n in nodes
       if n.get("frame") and any(abs(n["frame"].get(k, 0)) > 1e6 for k in ("x", "y", "width", "height"))]
if bad:
    print(f"FAIL: unrepresentable frames reached the wire: {bad[:3]}"); sys.exit(1)
PY
# One on-screen row must be ONE compact line. UIKit builds a picker row out of
# three views (cell, label, cell content view) and only the label can be named;
# the other two are anonymous rectangles at the same place. Folding them is what
# keeps this screen readable — measured before the fold: 86 lines for a two-column
# wheel, 46 of them carrying nothing actionable.
WHEEL_COMPACT="$("$HOST" --target ios ui compact "$TMP/wheel/snapshot.json")"
echo "$WHEEL_COMPACT" | grep -q "anonymous layer(s) folded" \
  || { echo "FAIL: the picker's anonymous layers must be folded and said out loud"; exit 1; }
# The fold, asserted in terms of its own rule: an anonymous `container`/`view`
# line is a LEFTOVER WRAPPER when it hugs a labelled line — contains its centre
# and is at most twice its area. Rendered before the fold this finds 84 of them
# on this screen; after, none. Two things it must NOT flag: the same value
# appearing twice at one spot (the picker draws magnifier bands, both are real
# labels, and `label:coincident` handles tapping them), and the scroll views,
# which carry `scroll:` and are identity, never folded.
printf '%s\n' "$WHEEL_COMPACT" > "$TMP/wheel-compact.txt"
/usr/bin/python3 - "$TMP/wheel-compact.txt" <<'PYFOLD' || exit 1
import re, sys
Q = chr(34)
pattern = re.compile(r"(\S+) (\w+)(?: " + Q + r"(.*?)" + Q + r")? \[(\d+),(\d+) (\d+)x(\d+)\](.*)")
rows = []
for line in open(sys.argv[1]).read().splitlines():
    m = pattern.match(line)
    if m:
        rows.append((m.group(1), m.group(2), m.group(3),
                     tuple(int(g) for g in m.group(4, 5, 6, 7)), m.group(8)))

def area(r):
    return r[3][2] * r[3][3]

def hugs(outer, inner):
    ox, oy, ow, oh = outer[3]
    ix, iy, iw, ih = inner[3]
    cx, cy = ix + iw / 2, iy + ih / 2
    inside = ox - 1 <= cx <= ox + ow + 1 and oy - 1 <= cy <= oy + oh + 1
    return inside and area(inner) <= area(outer) <= 2 * area(inner)

labelled = [r for r in rows if r[2]]
anon = [r for r in rows if r[1] in ("container", "view") and not r[2]
        and r[0].startswith("r") and "scroll:" not in r[4]]
leftovers = [(a, l) for a in anon for l in labelled if hugs(a, l)]
if leftovers:
    print("FAIL: %d anonymous layer(s) still wrap a labelled line:" % len(leftovers))
    for a, l in leftovers[:4]:
        print("   %s %s %s  wraps  %s %r %s" % (a[0], a[1], a[3], l[0], l[2], l[3]))
    sys.exit(1)
if not labelled:
    print("FAIL: no labelled rows in compact at all")
    sys.exit(1)
print("fold verified: %d labelled line(s), no anonymous wrapper left on any" % len(labelled))
PYFOLD
# The tappability has to MOVE to the survivor, or a folded row reads inert and an
# agent skips it. The picker itself is named, so the fold must leave it alone.
echo "$WHEEL_COMPACT" | grep -E '^r[0-9]+ text "[0-9]+"' | grep -q "tappable" \
  || { echo "FAIL: a folded picker row must inherit the tappability it absorbed"; exit 1; }
echo "$WHEEL_COMPACT" | grep -q "#wheel.picker" \
  || { echo "FAIL: the named picker must survive the fold"; exit 1; }

# Unlike Android, a neighbouring row IS a node here — tapping one selects it, and
# the app's committed state is the proof. Row 13 is three below the initial 09,
# inside the ~6 rows a picker renders.
"$HOST" --target ios --serial "$UDID" act tap --package "$LINKED_ID" --label "13"
sleep 1
# ...and now that 13 IS the selection, the same label must still be tappable.
# `UIPickerView` renders its magnifier bands as separate table views, so the row
# under the selection exists 2-3x at one spot (measured: '09' at 50,487 / 50,487 /
# 42,487) and `--label` on it was refused as ambiguous — for exactly the values
# worth tapping. Views stacked on ONE rect are one target; the tap reports
# `source=label:coincident` so the collapse is stated, not hidden.
STACKED_TAP="$("$HOST" --target ios --serial "$UDID" act tap --package "$LINKED_ID" --label "13" 2>&1 || true)"
echo "$STACKED_TAP"
echo "$STACKED_TAP" | grep -q "Refusing to guess" \
  && { echo "FAIL: views stacked on one rect must not read as an ambiguous label: $STACKED_TAP"; exit 1; }
echo "$STACKED_TAP" | grep -q "source=label" \
  || { echo "FAIL: the selected row must still resolve by label, got: $STACKED_TAP"; exit 1; }
sleep 1
"$HOST" --target ios --serial "$UDID" act tap --package "$LINKED_ID" --test-id wheel.confirm \
  --verify 'testId=wheel.status' | tee "$TMP/wheel-confirm.txt"
grep -q "Time: 13:" "$TMP/wheel-confirm.txt" \
  || { echo "FAIL: a tap on a picker row must change the committed value to 13"; exit 1; }
# A swipe along the wheel must land too — the gesture Android is limited to, so
# both platforms are driven the same way at least once. This is also the command
# that crashed the host before the rect fix, so a clean exit is part of the test.
"$HOST" --target ios --serial "$UDID" act swipe --package "$LINKED_ID" \
  --from 115,530 --to 115,455 --duration 300 --trace-output "$TMP/wheel-trace"
sleep 1
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/wheel-swiped"
"$HOST" --target ios ui regions "$TMP/wheel-swiped/snapshot.json" | grep -q 'a11yVirtual "13"' \
  && { echo "FAIL: the swipe did not move the hour wheel off 13"; exit 1; }
WHEEL_LOGS="$("$HOST" --target ios debug logs --package "$LINKED_ID")"
echo "$WHEEL_LOGS" | grep -q "wheel_hour_changed" \
  || { echo "FAIL: expected wheel_hour_changed in the app log bridge"; exit 1; }
echo "$WHEEL_LOGS" | grep -q "wheel_confirmed" \
  || { echo "FAIL: expected wheel_confirmed in the app log bridge"; exit 1; }
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
# Computed CSS is the DOM's style channel on BOTH platforms — a WKWebView and an
# android.webkit.WebView must answer `ui style` alike. The values keep their own
# suffixes and are NOT converted: a page's zoom and viewport scaling are not
# observable from in-process, so a CSS px is not a UIKit point and must never be
# rendered as one. A computed value at its CSS initial is dropped, since
# getComputedStyle answers for every property whether or not the page stated it.
WEB_STYLE="$("$HOST" --target ios ui style "$TMP/webview/snapshot.json")"
echo "$WEB_STYLE" | grep -A 8 computedStyle | head -12
echo "$WEB_STYLE" | grep -qE "domStyleFontSize +[0-9]+px +\\[computedStyle\\]" \
  || { echo "FAIL: expected a domStyleFontSize via computedStyle on iOS"; exit 1; }
echo "$WEB_STYLE" | grep -qE "domStyleFontSize +[0-9]+px +\\| " \
  && { echo "FAIL: a computed CSS length was converted — a CSS px is not a UIKit point"; exit 1; }
echo "$WEB_STYLE" | grep -qE "domStyle\\w+ +(auto|none|static|visible|0px) " \
  && { echo "FAIL: a computed style at its CSS initial value must be dropped, not printed"; exit 1; }
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
# The screenshot's own blind spot, on the same screen. The keyboard's host window
# refuses to render into a borrowed context (`drawHierarchy` returns false), and the
# capture skips it rather than let it black out everything below — correct, but
# silent until now. Measured on iOS 26.3: over the keys the agent's picture is the
# app's plain background (255,255,255) while `simctl io screenshot` shows the
# keyboard (239,240,242 / 226,228,232). So the absence gets labelled, exactly as
# `dom:unavailable` labels an unreadable DOM: `pixels:unavailable` on the window,
# plus a `degraded:` line on the picture that is missing it.
echo "$LOGIN_COMPACT" | grep "window" | grep -q "pixels:unavailable" \
  || { echo "FAIL: the keyboard host window must be marked pixels:unavailable"; exit 1; }
"$HOST" --target ios ui screenshot --package "$LINKED_ID" --output "$TMP/login-shot.png" | tee "$TMP/login-shot.txt"
grep -q "is not in this picture" "$TMP/login-shot.txt" \
  || { echo "FAIL: the screenshot must report the window it could not capture"; exit 1; }
# A wait for the covered button must RESOLVE — it is targetable, and the next act
# resolves it the same way — carrying the occlusion as a caveat plus the command
# that clears it. Testing isVisible instead (the reason an earlier wait proposal
# was dropped) would have turned this into a spurious failure.
WAIT_OCCLUDED="$("$HOST" --target ios act wait --package "$LINKED_ID" --for '#login.submitButton' --timeout 3000)"
echo "$WAIT_OCCLUDED"
echo "$WAIT_OCCLUDED" | grep -q "RESOLVED" \
  || { echo "FAIL: a keyboard-covered but targetable button must still be RESOLVED"; exit 1; }
echo "$WAIT_OCCLUDED" | grep -q "caveats: occluded-by:keyboard" \
  || { echo "FAIL: the resolved wait must carry the occlusion as a caveat"; exit 1; }
echo "$WAIT_OCCLUDED" | grep -q "next: act hide-keyboard" \
  || { echo "FAIL: the occlusion caveat must suggest hide-keyboard"; exit 1; }
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

echo "== OVERLAY WINDOW (a real second UIWindow occludes what is beneath) =="
# The window-vs-window occlusion path had never fired on iOS: every UIWindow was
# captured as kind=.view, and `CompactObservation` walks the application node's
# WINDOW children to compute occlusion. So an overlay window covering the screen
# left the controls underneath looking perfectly tappable — the exact silent
# wrongness this suite exists to catch. Windows are now kind=.window.
export SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO=overlayWindow
HOLD="$(hold_launch "$LINKED_ID")"; sleep 2
unset SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/overlay-before"
"$HOST" --target ios ui compact "$TMP/overlay-before/snapshot.json" | grep "overlay.covered" | grep -q "occluded-by" \
  && { echo "FAIL: nothing should be occluded before the overlay window exists"; exit 1; }
"$HOST" --target ios act activate --package "$LINKED_ID" --test-id overlay.trigger
sleep 2
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/overlay-up"
OVERLAY="$("$HOST" --target ios ui compact "$TMP/overlay-up/snapshot.json")"
echo "$OVERLAY"
echo "$OVERLAY" | grep "overlay.covered" | grep -q "occluded-by" \
  || { echo "FAIL: a control under an overlay UIWindow must be reported occluded-by"; exit 1; }
echo "$OVERLAY" | grep -q "overlay.label" \
  || { echo "FAIL: the overlay window's own content must be captured"; exit 1; }
# The overlay's own button is reachable by label even though window scoping now
# applies — and dismissing it must clear the occlusion.
"$HOST" --target ios --serial "$UDID" act tap --package "$LINKED_ID" --label "Dismiss overlay"
sleep 2
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/overlay-gone"
GONE="$("$HOST" --target ios ui compact "$TMP/overlay-gone/snapshot.json")"
echo "$GONE" | grep -q "Overlay dismissed" \
  || { echo "FAIL: tapping the overlay's dismiss button did not land"; exit 1; }
echo "$GONE" | grep "overlay.covered" | grep -q "occluded-by" \
  && { echo "FAIL: occlusion must clear once the overlay window is gone"; exit 1; }
kill "$HOLD" 2>/dev/null || true

echo "== SYSTEM DIALOG (UIAlertController) =="
# A UIAlertController raised over the scenario. Unlike Android's AlertDialog
# (a distinct WindowManagerGlobal root), iOS presents the alert *inside* the
# presenting window's hierarchy, so this asserts the capture surfaces the alert's
# own content — title / message / actions — and deliberately makes no occluded-by
# assertion: there is no second window here to occlude anything. That is a
# presentation difference, NOT a missing capability — the overlay-window section
# above proves window-vs-window occlusion does fire on iOS for a real second
# UIWindow.
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
#
# `--settle` rides along here, and the settling delay above it (the `sleep 1` after
# `activate`, plus the captures in between) STAYS on purpose. Measured
# on iOS 26.3: the alert's accessibility frame is FINAL from the first capture
# ([205,463 140x48], unchanged across six back-to-back captures) because
# UIAlertController animates in with a transform/alpha, not a layout change — yet a
# tap dispatched immediately after `activate` never lands (three runs, dialog.status
# stayed "No choice yet"), while the same tap ~1s later does. So settle honestly
# reports `settled=true` at once and cannot help: "the position stopped moving" is
# not "the view is hit-testable yet". Android's popup case is the one it fixes (see
# the PopupMenu note in scripts/e2e-android.sh). Asserted here so the flag's iOS path
# has coverage, and so this distinction is not quietly forgotten.
DIALOG_TAP="$("$HOST" --target ios --serial "$UDID" act tap --package "$LINKED_ID" --label "Delete" --settle)"
echo "$DIALOG_TAP"
echo "$DIALOG_TAP" | grep -q "settled=true" \
  || { echo "FAIL: tap --settle must report the settled position on iOS, got: $DIALOG_TAP"; exit 1; }
# ...and it must refuse a raw point rather than pretend it waited for one.
SETTLE_ERR="$("$HOST" --target ios --serial "$UDID" act tap --package "$LINKED_ID" --point 100,100 --settle 2>&1 || true)"
echo "$SETTLE_ERR" | grep -q "settle needs a selector" \
  || { echo "FAIL: --settle with --point must be refused, got: $SETTLE_ERR"; exit 1; }
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

echo "== WEB DOM BLOCKED (unreadable DOM degrades to dom:unavailable) =="
# The DOM bridge caps its evaluateJavaScript wait and, on failure, keeps the web
# view as ONE opaque node. An absence is ambiguous, so the node must also SAY the
# DOM was unreadable — otherwise "blocked bridge" and "empty page" are the same
# observation. Android produces this with a JS `alert()`; on iOS a page's alert()
# never reaches the app's WKUIDelegate in this configuration (measured), so the page
# blocks its own JS thread with a bounded busy loop — the same condition, and it
# clears itself so recovery is observable.
export SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO=webDomBlocked
HOLD="$(hold_launch "$LINKED_ID")"; sleep 3
unset SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/dom-ok"
"$HOST" --target ios ui compact "$TMP/dom-ok/snapshot.json" | grep -q "jsDialog.busyButton" \
  || { echo "FAIL: expected the page's DOM nodes before blocking its JS thread"; exit 1; }
# Block the page's JS thread, then capture while it is blocked.
"$HOST" --target ios --serial "$UDID" act tap --package "$LINKED_ID" --css "#js-busy"
START="$(date +%s)"
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/dom-blocked"
ELAPSED=$(( $(date +%s) - START ))
[ "$ELAPSED" -lt 20 ] \
  || { echo "FAIL: capture took ${ELAPSED}s with the page's JS blocked — degrade, don't block"; exit 1; }
DOM_BLOCKED="$("$HOST" --target ios ui compact "$TMP/dom-blocked/snapshot.json")"
echo "$DOM_BLOCKED"
echo "$DOM_BLOCKED" | grep -q "dom:unavailable" \
  || { echo "FAIL: an unreadable DOM must be reported as dom:unavailable"; exit 1; }
echo "$DOM_BLOCKED" | grep -q "jsDialog.busyButton" \
  && { echo "FAIL: no DOM nodes should be reported while the page's JS is blocked"; exit 1; }
# The degrade is scoped to the web view: native content on the same screen stays.
echo "$DOM_BLOCKED" | grep -q "domBlocked.status" \
  || { echo "FAIL: native content next to the web view must still be captured"; exit 1; }
# Once the loop ends the bridge answers again — the marker must clear, not stick.
sleep 5
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/dom-back"
DOM_BACK="$("$HOST" --target ios ui compact "$TMP/dom-back/snapshot.json")"
echo "$DOM_BACK" | grep -q "Busy done" \
  || { echo "FAIL: the page's JS did not finish / DOM never came back"; exit 1; }
echo "$DOM_BACK" | grep -q "dom:unavailable" \
  && { echo "FAIL: dom:unavailable must clear once the DOM is readable again"; exit 1; }
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

echo "== SYSTEM PERMISSION PROMPT (out of process: focus evidence) =="
# The one on-screen thing an in-process agent structurally CANNOT capture: the
# alert belongs to another process, so it is in no window of this app and no node of
# this tree, yet it takes every touch. Reticle cannot show it; it CAN report that
# this app is no longer the active recipient of input
# (`screen.windowFocused == false`). The Android twin asserts the same evidence.
#
# This section runs LAST and holds the two facts that make it scriptable at all
# (both measured on iOS 26.3 — do not "simplify" them away):
#   - RE-ARM. Once answered, the authorization is remembered, and
#     `xcrun simctl privacy … reset notifications` fails outright ("Operation not
#     permitted"), so a second run would never see a prompt. Re-INSTALLING the
#     bundle does reset it to notDetermined — hence the reinstall here, and hence
#     last: it wipes the linked app's container.
#   - ANSWER. Nothing in simctl can answer an open alert (`simctl privacy grant` ->
#     "Operation not permitted"; terminating the app leaves the alert standing), and
#     an unanswered alert silently swallows every later HID tap. A coordinate HID tap
#     does answer it: the buttons sit at ~57% of screen height, ~32% (deny) and ~68%
#     (allow) of its width. Coordinates only, no text is read, so the simulator's
#     language does not matter. Answer -> retry -> re-check, so a missed tap fails
#     loudly instead of poisoning the run.
xcrun simctl terminate "$UDID" "$LINKED_ID" 2>/dev/null || true
xcrun simctl uninstall "$UDID" "$LINKED_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$LINKED_APP" >/dev/null
export SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO=permission
HOLD="$(hold_launch "$LINKED_ID")"; sleep 3
unset SIMCTL_CHILD_RETICLE_SAMPLE_SCENARIO
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/permission-before"
"$HOST" --target ios ui compact "$TMP/permission-before/snapshot.json" | grep -q "UNFOCUSED" \
  && { echo "FAIL: the app should hold focus before the prompt is raised"; exit 1; }
"$HOST" --target ios --serial "$UDID" act tap --package "$LINKED_ID" --test-id permission.trigger
sleep 3
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/permission"
PERM_COMPACT="$("$HOST" --target ios ui compact "$TMP/permission/snapshot.json")"
echo "$PERM_COMPACT"
echo "$PERM_COMPACT" | head -1 | grep -q "UNFOCUSED" \
  || { echo "FAIL: compact must LEAD with the lost-focus evidence while the prompt is up"; exit 1; }
# The trap this evidence exists for: the tree is unchanged and still calls the
# app's own controls tappable, while a touch would in fact go to the alert.
echo "$PERM_COMPACT" | grep "permission.trigger" | grep -q "tappable" \
  || { echo "FAIL: expected the app's controls to still be captured (that IS the trap)"; exit 1; }
# The strongest case for the three-state outcome. permission.status genuinely has
# not changed — but only because nobody answered a prompt this process cannot see,
# so `absent` would be a lie an agent would act on. It must be UNKNOWABLE.
WAIT_UNFOCUSED="$("$HOST" --target ios act wait --package "$LINKED_ID" --for '#permission.status' --text 'granted' --timeout 3000)"
echo "$WAIT_UNFOCUSED"
echo "$WAIT_UNFOCUSED" | grep -q "UNKNOWABLE" \
  || { echo "FAIL: a wait behind another process's window must be UNKNOWABLE, never ABSENT"; exit 1; }
echo "$WAIT_UNFOCUSED" | grep -q "reasons:.*window-unfocused" \
  || { echo "FAIL: the unknowable verdict must name the lost window focus"; exit 1; }
set +e
"$HOST" --target ios act wait --package "$LINKED_ID" --for '#permission.status' --text 'granted' --timeout 1500 --strict >/dev/null
WAIT_RC_UNFOCUSED=$?
set -e
[ "$WAIT_RC_UNFOCUSED" -eq 4 ] \
  || { echo "FAIL: --strict behind a foreign window exited $WAIT_RC_UNFOCUSED, expected 4"; exit 1; }
/usr/bin/python3 - "$TMP/permission-before/snapshot.json" "$TMP/permission/snapshot.json" <<'PYEOF' || exit 1
import json, sys
before = json.load(open(sys.argv[1]))
after = json.load(open(sys.argv[2]))
if before["screen"].get("windowFocused") is not True:
    print("FAIL: screen.windowFocused should be true before the prompt is raised")
    sys.exit(1)
if after["screen"].get("windowFocused") is not False:
    print("FAIL: screen.windowFocused should be false while another window has focus")
    sys.exit(1)
# The boundary itself, asserted so nobody later mistakes silence for capture: the
# alert added NOTHING to the tree. Stated by SHAPE (the node set is unchanged while
# a foreign window is on top), not by matching the alert's wording — the alert is
# localized, so a text check would assert nothing on a non-English simulator.
if len(after["nodes"]) != len(before["nodes"]):
    print("FAIL: the node set changed while the out-of-process alert was up "
          f"({len(before['nodes'])} -> {len(after['nodes'])}); an in-process capture "
          "must neither see that window nor lose its own")
    sys.exit(1)
PYEOF
# Answer the alert with a coordinate tap (deny), derived from the screen size.
DENY_PT="$(/usr/bin/python3 -c 'import json,sys
s = json.load(open(sys.argv[1]))["screen"]["size"]
print("%d,%d" % (s["width"] * 0.32, s["height"] * 0.568))' "$TMP/permission/snapshot.json")"
ANSWERED=0
for _ in 1 2 3; do
  "$HOST" --target ios --serial "$UDID" act tap --package "$LINKED_ID" --point "$DENY_PT" || true
  sleep 2
  if ! "$HOST" --target ios ui compact --live --package "$LINKED_ID" | grep -q "UNFOCUSED"; then
    ANSWERED=1; break
  fi
done
[ "$ANSWERED" = 1 ] \
  || { echo "FAIL: could not answer the permission alert at $DENY_PT — focus evidence never cleared"; exit 1; }
# ...and the app's own state proves the tap ANSWERED the alert rather than the alert
# merely going away: the authorization callback ran with granted=false.
"$HOST" --target ios ui report --package "$LINKED_ID" --output "$TMP/permission-answered"
"$HOST" --target ios ui compact "$TMP/permission-answered/snapshot.json" \
  | grep "permission.status" | grep -q "Prompt dismissed" \
  || { echo "FAIL: the deny tap did not reach the alert (permission.status never settled)"; exit 1; }
"$HOST" --target ios debug logs --package "$LINKED_ID" | grep -q "permission_result" \
  || { echo "FAIL: expected permission_result in the app log bridge"; exit 1; }
kill "$HOLD" 2>/dev/null || true

echo "== OK: artifacts in $TMP =="
