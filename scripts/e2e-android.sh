#!/usr/bin/env bash
# End-to-end smoke test for the Android agent on a device or emulator. Builds the
# agent AAR + dex payload and both sample-app flavors, installs them, and
# exercises the full round trip through the Swift host + native helper: linked
# launch, ui report, compact, selector taps with --verify and --trace-output,
# runtime mutation, agreement-region resolution, WebView DOM, the login
# keyboard trap, the system dialog (AlertDialog window recognition + occlusion),
# the native Lottie dialog, the web Lottie modal, the web-component (shadow DOM)
# modal, the Lottie-only dialog (recovering elements baked into one Lottie), and
# the JDWP injection path on the noagent flavor.
#
# This is the Android analogue of scripts/e2e-ios.sh. Every action step asserts
# an OBSERVABLE side effect — a tap that merely "doesn't error" is worthless;
# the failure mode we guard against is synthesized input that dispatches cleanly
# yet never reaches a control, or a capture that silently drops on-screen state.
#
# Requires: a booted device/emulator in the `device` state, a JDK 17 for the
# Gradle build, and prebuilt host binaries:
#   swift build --package-path reticle-host          # -> ReticleHost
#   ./gradlew :reticle-helper:nativeHelper           # -> reticle-helper (native)
# Pass a device serial as $1, or the single attached device is used.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

HOST="${RETICLE_HOST:-$ROOT/reticle-host/.build/debug/ReticleHost}"
HELPER="${RETICLE_HELPER:-$ROOT/reticle-helper/build/native/reticle-helper}"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="${RETICLE_ADB:-$SDK/platform-tools/adb}"
SERIAL="${1:-}"
PKG="dev.reticle.sample"
NOAGENT="dev.reticle.sample.noagent"
TMP="$(mktemp -d)"

export RETICLE_HELPER="$HELPER"
export RETICLE_ADB="$ADB"
# One-shot commands here reset the app between scenarios, so the resident helper
# daemon's warm reuse is what we want; leave it on (its default). Nothing to set.

[ -x "$HOST" ]   || { echo "build the host first: swift build --package-path reticle-host"; exit 1; }
[ -x "$HELPER" ] || { echo "build the native helper first: ./gradlew :reticle-helper:nativeHelper"; exit 1; }
[ -x "$ADB" ]    || { echo "adb not found at $ADB; set ANDROID_HOME or RETICLE_ADB"; exit 1; }

# Resolve a single device when no serial was passed; fail loudly on ambiguity so
# input never lands on the wrong device.
if [ -z "$SERIAL" ]; then
  mapfile -t DEVS < <("$ADB" devices | awk 'NR>1 && $2=="device"{print $1}')
  [ "${#DEVS[@]}" -eq 1 ] || { echo "expected exactly one device; found: ${DEVS[*]:-none}. Pass a serial as \$1."; exit 1; }
  SERIAL="${DEVS[0]}"
fi
export ANDROID_SERIAL="$SERIAL"
R() { "$HOST" --serial "$SERIAL" "$@"; }
echo "== device: $SERIAL =="

# Cold-start the app and wait for the in-process runtime to answer, polling
# `status` rather than blocking a single `app launch` call on its internal
# await. A cold start on a software-GPU emulator can take 20-40s for the agent
# to bind; polling short probes rides that out (and is generous enough that a
# real device, where this is ~2s, never notices).
wait_runtime() { # package
  local pkg="$1" deadline=$(( $(date +%s) + 120 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if R status --package "$pkg" 2>/dev/null | grep -q "runtime: healthy"; then return 0; fi
    sleep 2
  done
  echo "FAIL: $pkg runtime never became healthy within 120s"; exit 1
}
# Poll a live compact until it contains `needle`, so we proceed only once the
# expected window has actually drawn. The agent's server binds when the process
# starts — which can be BEFORE the first Activity attaches its window — so a
# healthy runtime alone does not mean on-screen content is present yet.
wait_compact() { # package needle
  local pkg="$1" needle="$2" last="" deadline=$(( $(date +%s) + 60 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    last="$(R ui compact --live --package "$pkg" 2>&1 || true)"
    if printf '%s' "$last" | grep -q "$needle"; then return 0; fi
    sleep 2
  done
  # Print what WAS on screen. A bare timeout cannot distinguish "the tap never
  # landed" from "the dialog is up but the capture degraded under animation load" —
  # the shape of the flake this suite has hit twice on a software-GPU emulator.
  echo "FAIL: '$needle' never appeared on screen for $pkg within 60s"
  echo "--- last observation (why it timed out) ---"
  printf '%s\n' "$last"
  echo "-------------------------------------------"
  exit 1
}
boot_app() { # package
  "$ADB" -s "$SERIAL" shell am force-stop "$1" >/dev/null 2>&1 || true
  sleep 1
  "$ADB" -s "$SERIAL" shell monkey -p "$1" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  wait_runtime "$1"
  # The home list is where every scenario starts; wait until it is on screen.
  wait_compact "$1" "home.title"
}

echo "== build agent + sample apps =="
JHOME="$(/usr/libexec/java_home -v 17 2>/dev/null || true)"
JAVA_HOME="${JAVA_HOME:-$JHOME}" ./gradlew \
  :reticle-agent:android:dexPayload \
  :sample-app:assembleLinkedDebug \
  :sample-app:assembleNoagentDebug >/dev/null
PAYLOAD_DEX="$ROOT/reticle-agent/android/build/reticle-payload/reticle-agent-payload.jar"
[ -f "$PAYLOAD_DEX" ] || { echo "FAIL: payload dex not built at $PAYLOAD_DEX"; exit 1; }
export RETICLE_PAYLOAD_DEX="$PAYLOAD_DEX"

echo "== install sample apps =="
"$ADB" -s "$SERIAL" install -r -t sample-app/build/outputs/apk/linked/debug/sample-app-linked-debug.apk >/dev/null
"$ADB" -s "$SERIAL" install -r -t sample-app/build/outputs/apk/noagent/debug/sample-app-noagent-debug.apk >/dev/null
# Force the soft keyboard to show even with a hardware keyboard attached — the
# emulator default suppresses the IME otherwise, and the login keyboard-trap
# assertions can never hold without it.
"$ADB" -s "$SERIAL" shell settings put secure show_ime_with_hard_keyboard 1 >/dev/null 2>&1 || true
# Wake and unlock: a freshly booted/idle device can sit with the screen off or
# on the keyguard, so a launched Activity never foregrounds and the captured
# window is the keyguard (no scenario rows). Turn the screen on and dismiss it.
"$ADB" -s "$SERIAL" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
"$ADB" -s "$SERIAL" shell wm dismiss-keyguard >/dev/null 2>&1 || true

# Reset to the home screen (fresh MainActivity) then open one scenario row.
# Android navigates via tappable home rows (tag = scenario.testId), one Activity
# per scenario — unlike the iOS scenario env var.
open_scenario() { # rowTestId readyNeedle
  boot_app "$PKG"
  # The scenario list is taller than one screen, so a row can be below the fold —
  # a tap on a clipped row resolves to coordinates that land on the system
  # navigation bar and silently does nothing. `act scroll-to` brings it in first
  # (and dogfoods the primitive that exists for exactly this).
  R act scroll-to --package "$PKG" --test-id "$1" >/dev/null
  R act tap --package "$PKG" --test-id "$1" >/dev/null
  # Wait for the scenario Activity's own content to draw — the transition can
  # take several seconds on a software-GPU emulator, longer than a fixed sleep.
  wait_compact "$PKG" "$2"
}

echo "== LINKED path: home =="
boot_app "$PKG"
R status --package "$PKG"
R ui report --package "$PKG" --output "$TMP/home"
HOME_COMPACT="$(R ui compact "$TMP/home/snapshot.json")"
echo "$HOME_COMPACT"
echo "$HOME_COMPACT" | grep -q "scenario.checkout" \
  || { echo "FAIL: home snapshot missing the scenario rows"; exit 1; }
# Style evidence on the classic View path: Android lengths are physical pixels, so
# every length must also come out in dp (a design states dp) and text also in sp
# (which divides out the system font scale). The Typeface gap is asserted too: a
# Typeface names no family, and that has to say so rather than look like a font the
# app never set.
HOME_STYLE="$(R ui style "$TMP/home/snapshot.json")"
echo "$HOME_STYLE" | head -25
echo "$HOME_STYLE" | grep -qE "^screen: [0-9.]+x[0-9.]+px density=[0-9.]+ fontScale=[0-9.]+ -> [0-9.]+x[0-9.]+dp$" \
  || { echo "FAIL: screen line must carry px, density, a probed fontScale and the dp size"; exit 1; }
echo "$HOME_STYLE" | grep -qE "textSize +[0-9.]+px \| [0-9.]+dp \| [0-9.]+sp +\[viewField\]" \
  || { echo "FAIL: expected a TextView textSize in px|dp|sp via viewField"; exit 1; }
echo "$HOME_STYLE" | grep -qE "paddingLeft +[0-9.]+px \| [0-9.]+dp" \
  || { echo "FAIL: expected padding in px|dp — a frame gap cannot say whose padding it is"; exit 1; }
echo "$HOME_STYLE" | grep -q "! fontFamily  unreadable: android-typeface-exposes-no-family" \
  || { echo "FAIL: the Typeface family gap must declare itself"; exit 1; }

echo "== CHECKOUT: tap + verify + trace =="
R act tap --package "$PKG" --test-id scenario.checkout >/dev/null
wait_compact "$PKG" "checkout.payButton"
R ui report --package "$PKG" --output "$TMP/checkout"
R ui compact "$TMP/checkout/snapshot.json" | grep -q "checkout.payButton" \
  || { echo "FAIL: checkout screen missing payButton"; exit 1; }
R ui screenshot --package "$PKG" --output "$TMP/shot.png"
[ -s "$TMP/shot.png" ] || { echo "FAIL: screenshot produced no artifact"; exit 1; }
# The tap must LAND: checkout.status flips "Cart: 3 items" -> "Paid!". --verify
# watches that node before/after (the testId= spelling exercises the parser fix
# from PR #95), and --trace-output writes the evidence package.
VERIFY_OUT="$(R act tap --package "$PKG" --test-id checkout.payButton \
  --verify 'testId=checkout.status' --trace-output "$TMP/trace")"
echo "$VERIFY_OUT"
echo "$VERIFY_OUT" | grep -q "Paid!" \
  || { echo "FAIL: --verify did not record checkout.status changing to Paid!"; exit 1; }
sleep 1
R ui report --package "$PKG" --output "$TMP/checkout-paid"
R ui compact "$TMP/checkout-paid/snapshot.json" | grep -q "Paid!" \
  || { echo "FAIL: tap on payButton did not land (checkout.status never became Paid!)"; exit 1; }
TRACE_JSON="$(find "$TMP/trace" -name trace.json | head -1)"
[ -n "$TRACE_JSON" ] || { echo "FAIL: no action-trace manifest under --trace-output"; exit 1; }
grep -q '"gesture": *"tap"' "$TRACE_JSON" \
  || { echo "FAIL: trace.json missing the tap gesture"; exit 1; }
grep -q '"platform": *"android"' "$TRACE_JSON" \
  || { echo "FAIL: trace.json missing platform=android"; exit 1; }
# The diff must record the observable change (checkout.status -> Paid!).
grep -q "Paid!" "$TRACE_JSON" \
  || { echo "FAIL: trace.json diff did not record the checkout.status change"; exit 1; }
[ -f "$(dirname "$TRACE_JSON")/before.snapshot.json" ] && [ -f "$(dirname "$TRACE_JSON")/after.snapshot.json" ] \
  || { echo "FAIL: trace missing before/after snapshot artifacts"; exit 1; }
# replay gif stitches the recorded trace into the animated evidence artifact
# (host-local, no device). It must find the screenshots the trace just wrote.
R replay gif "$TMP/trace" >/dev/null
[ -s "$TMP/trace/replay.gif" ] || { echo "FAIL: replay gif produced no artifact"; exit 1; }
# App-authored log bridge: the checkout logs must surface through /logs.
R debug logs --package "$PKG" | grep -q "checkout_paid" \
  || { echo "FAIL: expected checkout_paid in the app log bridge"; exit 1; }

echo "== WAIT: three-state outcome (resolved / absent) + --strict exit codes =="
# `act wait` is the primitive for crossing an async boundary: --verify can only
# watch a node that ALREADY resolves, so "act, then a NEW screen appears" is
# inexpressible without this. What must hold here is the separation of its three
# outcomes — an agent may act on `absent` but must only switch tactics on
# `unknowable`, so the two can never be conflated.
#
# checkout.status is "Paid!" by now, so a matching text predicate is satisfied.
WAIT_OK="$(R act wait --package "$PKG" --for '#checkout.status' --text 'Paid' --timeout 4000)"
echo "$WAIT_OK"
echo "$WAIT_OK" | grep -q "RESOLVED" \
  || { echo "FAIL: wait on the already-flipped checkout.status was not RESOLVED"; exit 1; }
# The predicate must be echoed verbatim: a caller should never have to infer what
# was waited on.
echo "$WAIT_OK" | grep -q 'text testId=checkout.status contains "Paid"' \
  || { echo "FAIL: wait did not echo the predicate it was given"; exit 1; }
# A predicate that will never come true on a SETTLED screen, against a node that
# DOES resolve. Resolution is what immunizes this from scroll doubt, so it must
# be an honest `absent` and must report what was actually on the node.
WAIT_ABSENT="$(R act wait --package "$PKG" --for '#checkout.status' --text 'NeverGonnaHappen' --timeout 3000)"
echo "$WAIT_ABSENT"
echo "$WAIT_ABSENT" | grep -q "ABSENT" \
  || { echo "FAIL: a settled miss on a resolved node must be ABSENT, not unknowable"; exit 1; }
echo "$WAIT_ABSENT" | grep -q 'observed: "Paid!"' \
  || { echo "FAIL: an absent text predicate must report the text it DID find"; exit 1; }
# `ok` stays true and the default exit stays 0: a predicate that did not come
# true is an observation, not a tool failure.
R act wait --package "$PKG" --for '#checkout.status' --text 'NeverGonnaHappen' --timeout 1500 --json \
  | grep -q '"ok":true' \
  || { echo "FAIL: a timed-out wait must still be ok:true in the JSON envelope"; exit 1; }
# --strict projects the outcome onto an exit code for shell/CI callers. 3 and 4
# must stay distinct: 3 says "this is not there", 4 says "I could not see".
set +e
R act wait --package "$PKG" --for '#checkout.status' --text 'Paid' --timeout 3000 --strict >/dev/null
WAIT_RC_OK=$?
R act wait --package "$PKG" --for '#checkout.status' --text 'NeverGonnaHappen' --timeout 1500 --strict >/dev/null
WAIT_RC_ABSENT=$?
set -e
[ "$WAIT_RC_OK" -eq 0 ] || { echo "FAIL: --strict on a resolved wait exited $WAIT_RC_OK, expected 0"; exit 1; }
[ "$WAIT_RC_ABSENT" -eq 3 ] || { echo "FAIL: --strict on an absent wait exited $WAIT_RC_ABSENT, expected 3"; exit 1; }
# `gone` on a selector that never existed holds immediately.
R act wait --package "$PKG" --for '#no.such.node.anywhere' --gone --timeout 2000 | grep -q "RESOLVED" \
  || { echo "FAIL: gone on a nonexistent selector was not RESOLVED"; exit 1; }
# `--idle` waits for the SCREEN, states no expectation about content, and so can
# never report `absent`. It must also return as soon as the screen is quiet
# rather than burning its whole budget.
WAIT_IDLE="$(R act wait --package "$PKG" --idle --timeout 20000)"
echo "$WAIT_IDLE"
echo "$WAIT_IDLE" | grep -q "idle: RESOLVED" \
  || { echo "FAIL: --idle did not settle on a static screen"; exit 1; }
IDLE_MS="$(printf '%s' "$WAIT_IDLE" | sed -n 's/.*RESOLVED in \([0-9]*\)ms.*/\1/p')"
[ -n "$IDLE_MS" ] && [ "$IDLE_MS" -lt 5000 ] \
  || { echo "FAIL: --idle took ${IDLE_MS:-?}ms on a static screen; it must return once quiet, not at the deadline"; exit 1; }
# Predicates the tool cannot answer are refused rather than answered wrongly.
set +e
R act wait --package "$PKG" --point 10,20 --timeout 1000 >/dev/null 2>"$TMP/wait-point.err"
WAIT_RC_POINT=$?
set -e
[ "$WAIT_RC_POINT" -ne 0 ] || { echo "FAIL: wait --point must be refused (a coordinate always resolves)"; exit 1; }
grep -q -- "--point" "$TMP/wait-point.err" \
  || { echo "FAIL: the --point refusal must say why; got: $(cat "$TMP/wait-point.err")"; exit 1; }

echo "== CHECKOUT: type (ASCII + non-ASCII paste) =="
# ASCII goes through `input text`; the field must focus first (the helper taps
# the selector target before typing).
R act type --package "$PKG" --test-id checkout.nameField --text "Ada" >/dev/null
sleep 1
R ui report --package "$PKG" --output "$TMP/typed-ascii"
R ui compact "$TMP/typed-ascii/snapshot.json" | grep -q "Ada" \
  || { echo "FAIL: ASCII type did not land in checkout.nameField"; exit 1; }
# Non-ASCII rides the clipboard + paste path (requires a reachable runtime).
R act type --package "$PKG" --test-id checkout.nameField --text "你好" >/dev/null
sleep 1
R ui report --package "$PKG" --output "$TMP/typed-cjk"
R ui compact "$TMP/typed-cjk/snapshot.json" | grep -q "你好" \
  || { echo "FAIL: non-ASCII clipboard-paste type did not land"; exit 1; }

echo "== CHECKOUT: runtime mutation =="
R mutate --package "$PKG" --test-id checkout.payButton --property alpha --value 0.4 >/dev/null

echo "== AGREEMENT regions =="
open_scenario scenario.agreements agreement.markdown
R ui report --package "$PKG" --output "$TMP/agreements"
REGIONS="$(R ui regions "$TMP/agreements/snapshot.json")"
echo "$REGIONS"
echo "$REGIONS" | grep -q "span "      || { echo "FAIL: expected a span region (ClickableSpan/URLSpan)"; exit 1; }
echo "$REGIONS" | grep -q "textMarker" || { echo "FAIL: expected textMarker regions (self-drawn row)"; exit 1; }
echo "$REGIONS" | grep -q "colorSpan"  || { echo "FAIL: expected a colorSpan region (highlight=link)"; exit 1; }
# --region resolution must produce a tap point from a discovered region rect and
# from the char grid (plain phrase with no structural markers). These land input;
# they just must not error and must resolve a point.
R act tap --package "$PKG" --test-id agreement.markdown --region "Privacy" >/dev/null
R act tap --package "$PKG" --test-id agreement.plain --region "Privacy Policy" >/dev/null

echo "== POPUP WINDOWS (PopupWindow, Spinner dropdown, PopupMenu) + --label =="
# `AlertDialog` was already covered, but each of these attaches its own root to
# WindowManagerGlobal through a different framework path. They are also the case
# where a captured control has NO id of its own: dropdown rows and menu items share
# one resource id (`text1`, `title`), so `--label` (exact-then-substring, ambiguity
# refused) is the only stable way to single one out.
open_scenario scenario.popups popup.trigger
# 1. An app-authored PopupWindow: its content is a separate window root.
R act tap --package "$PKG" --test-id popup.trigger >/dev/null
wait_compact "$PKG" "popupWindow.title"
R act tap --package "$PKG" --test-id popupWindow.action >/dev/null
wait_compact "$PKG" "Popup applied"
# 2. A Spinner dropdown: framework popup, rows addressable only by label — and the
# first user of `--settle` (see the PopupMenu note below for the measured cause).
R act tap --package "$PKG" --test-id popup.spinner >/dev/null
wait_compact "$PKG" "Basic"
R act tap --package "$PKG" --label "Pro" --settle >/dev/null
wait_compact "$PKG" "Spinner: Pro"
# 3. A PopupMenu (the overflow shape), same story — and the case `tap --settle`
# exists for. A popup slides in, and `wait_compact` returns the moment its text is
# first captured, which can be MID-animation: the row's rect is then stale by the
# time the tap dispatches and the touch lands on its neighbour (measured on an
# emulator, 1 run in 5: the row was captured at y=1396, the tap resolved y=1474, the
# menu came to rest at y=1612, and `--label "Delete item"` fired "Menu: Rename").
# `--settle` re-resolves until the point repeats before dispatching, so the tap is
# aimed at where the row ENDED UP; `settled=1` is the report that it was confirmed
# stopped rather than merely resolved once.
R act tap --package "$PKG" --test-id popup.menuTrigger >/dev/null
wait_compact "$PKG" "Delete item"
MENU_TAP="$(R act tap --package "$PKG" --label "Delete item" --settle)"
echo "$MENU_TAP" | grep -q "settled=1" \
  || { echo "FAIL: tap --settle must report the settled position, got: $MENU_TAP"; exit 1; }
wait_compact "$PKG" "Menu: Delete item"
# --settle has nothing to re-resolve for a raw point, and must say so instead of
# silently pretending it waited.
SETTLE_ERR="$(R act tap --package "$PKG" --point 100,100 --settle 2>&1 || true)"
echo "$SETTLE_ERR" | grep -q "settle needs a selector" \
  || { echo "FAIL: --settle with --point must be refused, got: $SETTLE_ERR"; exit 1; }
# --label must REFUSE an ambiguous match rather than tap the first candidate: a
# silent wrong tap is the failure mode this whole suite exists to catch.
AMBIG="$(R act tap --package "$PKG" --label "Show" 2>&1 || true)"
echo "$AMBIG" | grep -q "matched 2 visible nodes" \
  || { echo "FAIL: an ambiguous --label must be refused, got: $AMBIG"; exit 1; }
POPUP_LOGS="$(R debug logs --package "$PKG")"
echo "$POPUP_LOGS" | grep -q "popup_menu_picked" \
  || { echo "FAIL: expected popup_menu_picked in the app log bridge"; exit 1; }

echo "== WHEEL PICKER (only the selected value is a node) =="
# The picker shape neither the Spinner dropdown nor the long list covers. A
# `NumberPicker` in spinner mode draws its neighbouring values onto the wheel
# canvas, so the ONLY child view it owns is the EditText holding the selection:
# there is no node for "10" to tap and none ever appears, however far you scroll.
# Reaching a value is a swipe, and the evidence is the selection's text changing.
open_scenario scenario.wheelPicker "wheel.status"
WHEEL="$(R ui compact --live --package "$PKG")"
echo "$WHEEL"
# Two wheels, both `numberpicker_input`, both `scroll:up,down`. The container
# marker is what tells an agent the wheel has travel rather than being inert.
echo "$WHEEL" | grep -q "#wheel.hour container .* scroll:up,down" \
  || { echo "FAIL: the wheel must report its scroll travel, got: $WHEEL"; exit 1; }
[ "$(echo "$WHEEL" | grep -c '#numberpicker_input')" = "2" ] \
  || { echo "FAIL: expected exactly one value node per wheel"; exit 1; }
# The boundary, asserted as an absence: a value the wheel is not on has no node.
echo "$WHEEL" | grep -qE '#numberpicker_input textField "(20|21)"' \
  && { echo "FAIL: an unselected wheel value must not appear as a node"; exit 1; }
# `scroll-to` is deliberately not attempted: it waits for a SELECTOR to resolve
# inside a container, and an unselected wheel value has no selector to name — the
# two wheels' only ids are `numberpicker_input`, which already resolves. So the
# primitive that rescues an unbound list row structurally cannot reach a wheel.
# Drive it the only way that works, and take the verdict from the app's own
# COMMITTED state rather than from the wheel's text. Two reasons, both measured:
# once the wheel has been scrolled the widget paints the value itself and marks its
# EditText INVISIBLE — permanently, on an API 36 emulator — so the value node drops
# out of `compact` while staying in the snapshot (asserted below); and the text can
# disagree with the value outright (see the `type` note further down). Committing
# before and after and requiring the two to differ is the assertion that cannot be
# satisfied by a no-op.
HOUR_BEFORE="$(echo "$WHEEL" | sed -nE 's/^#numberpicker_input textField "([0-9]+)".*/\1/p' | head -1)"
[ -n "$HOUR_BEFORE" ] \
  || { echo "FAIL: could not read the hour wheel's value from: $WHEEL"; exit 1; }
R act tap --package "$PKG" --test-id wheel.confirm >/dev/null
wait_compact "$PKG" "Time: "
TIME_BEFORE="$(R ui compact --live --package "$PKG" | grep -m1 '#wheel.status')"
# The swipe runs up the hour wheel's centre column — the only way to move a wheel.
# Its endpoints are DERIVED from the reported frame rather than hardcoded: the
# wheel's rect differs between a phone and an emulator, and a fixed coordinate
# would silently swipe empty background on the other one (a gesture that reports
# clean and does nothing is the failure this suite exists to catch).
read -r WHEEL_X WHEEL_FROM_Y WHEEL_TO_Y <<EOF
$(echo "$WHEEL" | sed -nE 's/^#wheel\.hour container .*\[([0-9]+),([0-9]+) ([0-9]+)x([0-9]+)\].*/\1 \2 \3 \4/p' \
   | awk '{ printf "%d %d %d\n", $1 + $3 / 2, $2 + $4 * 0.8, $2 + $4 * 0.2 }')
EOF
[ -n "${WHEEL_TO_Y:-}" ] \
  || { echo "FAIL: could not read the hour wheel's frame from: $WHEEL"; exit 1; }
R act swipe --package "$PKG" --from "$WHEEL_X,$WHEEL_FROM_Y" --to "$WHEEL_X,$WHEEL_TO_Y" --duration 300 >/dev/null
R act wait --package "$PKG" --idle >/dev/null
R act tap --package "$PKG" --test-id wheel.confirm >/dev/null
# Poll for the committed value to differ. A deadline rather than a fixed sleep:
# the confirm may land while the wheel is still settling, in which case the app
# commits the value it is on and the next confirm carries the final one.
WHEEL_DEADLINE=$(( $(date +%s) + 30 ))
TIME_AFTER="$TIME_BEFORE"
while [ "$(date +%s)" -lt "$WHEEL_DEADLINE" ]; do
  TIME_AFTER="$(R ui compact --live --package "$PKG" | grep -m1 '#wheel.status')"
  [ "$TIME_AFTER" != "$TIME_BEFORE" ] && break
  R act tap --package "$PKG" --test-id wheel.confirm >/dev/null
  sleep 1
done
[ "$TIME_AFTER" != "$TIME_BEFORE" ] \
  || { echo "FAIL: the swipe never moved the wheel's committed value (still $TIME_BEFORE)"; exit 1; }
echo "wheel: $TIME_BEFORE -> $TIME_AFTER"
# A scrolled wheel's value must stay READABLE even when it stops being *visible*.
# Measured on an API 36 emulator: after the swipe, `NumberPicker` leaves its
# CustomEditText INVISIBLE for good (it paints the value itself from then on), so
# `compact` — the projection an agent actually reads — shows a wheel with no value
# at all, while the node is still in the snapshot carrying the right text and still
# resolves by selector. On a real device (ColorOS, API 35) it stayed visible, so
# neither behaviour may be assumed. What is asserted is therefore the guarantee
# that holds either way: the full snapshot still answers "what is this wheel on",
# and the answer is the value the swipe moved it to.
R ui report --package "$PKG" --output "$TMP/wheel-settled" >/dev/null
/usr/bin/python3 - "$TMP/wheel-settled/snapshot.json" "$HOUR_BEFORE" <<'PY' || exit 1
import json, sys
nodes = json.load(open(sys.argv[1]))["nodes"]
nodes = nodes.values() if isinstance(nodes, dict) else nodes
# Document order is not guaranteed by the map, so pick the LEFTMOST wheel by frame.
inputs = sorted((n for n in nodes if n.get("resourceId") == "numberpicker_input"),
                key=lambda n: (n.get("frame") or {}).get("x", 0))
if len(inputs) != 2:
    print(f"FAIL: both wheel value nodes must stay in the snapshot, got {len(inputs)}")
    sys.exit(1)
hour = inputs[0]
if not hour.get("text"):
    print(f"FAIL: the scrolled wheel's node carries no value: {hour}"); sys.exit(1)
if hour["text"] == sys.argv[2]:
    print(f"FAIL: the hour wheel still reads {sys.argv[2]} after the swipe"); sys.exit(1)
print(f"wheel value node: {sys.argv[2]} -> {hour['text']} "
      f"(isVisible={hour.get('isVisible')}, so it may be absent from compact)")
PY
# NOTE on the gesture chosen above: `act type` into `numberpicker_input` is
# deliberately NOT used to set a wheel. It succeeds and is a lie — the EditText
# shows the typed text while the widget's value stays put until it validates on
# focus change (measured: typing 17 left the tree reading 17, the canvas
# neighbours reading 10/12, and `wheel.status` reading Time: 11:00). Recorded in
# docs/boundaries.md; a swipe is the honest driver.
WHEEL_LOGS="$(R debug logs --package "$PKG")"
echo "$WHEEL_LOGS" | grep -q "wheel_hour_changed" \
  || { echo "FAIL: expected wheel_hour_changed in the app log bridge"; exit 1; }
echo "$WHEEL_LOGS" | grep -q "wheel_confirmed" \
  || { echo "FAIL: expected wheel_confirmed in the app log bridge"; exit 1; }

echo "== LONG LIST (recycling boundary + scroll evidence) =="
# The commonest E2E dead end: a RecyclerView binds only its visible window, so a
# far-down row has NO node, frame, or selector — it is absent, not off-screen.
# Reticle can't invent it, but it CAN say the screen has a container that could
# still move, which is the difference between "not bound yet" and "this app
# doesn't have that element".
open_scenario scenario.list list.item0
R ui report --package "$PKG" --output "$TMP/list"
LIST_COMPACT="$(R ui compact "$TMP/list/snapshot.json")"
echo "$LIST_COMPACT"
echo "$LIST_COMPACT" | grep -q "list.rows.*scroll:down" \
  || { echo "FAIL: the RecyclerView must report it can still scroll down"; exit 1; }
/usr/bin/python3 - "$TMP/list/snapshot.json" <<'PY' || exit 1
import json, re, sys
nodes = json.load(open(sys.argv[1]))["nodes"].values()
rows = sorted(int(re.sub(r"\D", "", n["testId"]))
              for n in nodes if (n.get("testId") or "").startswith("list.item"))
if not rows or rows[0] != 0:
    print(f"FAIL: expected the first rows to be bound, got {rows}"); sys.exit(1)
if 40 in rows:
    print("FAIL: row 40 should NOT be bound yet — the recycling boundary is what this asserts")
    sys.exit(1)
PY
# Scroll evidence must also reach the selector-miss diagnostics, so a failing
# lookup explains itself instead of reading as "no such element".
MISS="$(R act tap --package "$PKG" --test-id list.item40 2>&1 || true)"
echo "$MISS" | grep -q "scrollable content" \
  || { echo "FAIL: a miss on an unbound row must mention the scrollable container: $MISS"; exit 1; }
# The same evidence must lift a `wait` out of `absent`. An unbound row has NO
# node at all, so its absence is not evidence — reporting it as `absent` would
# tell an agent the app is missing a feature it simply had not scrolled to. This
# is the single most important thing the three-state outcome buys.
WAIT_UNKNOWABLE="$(R act wait --package "$PKG" --for '#list.item40' --timeout 3000)"
echo "$WAIT_UNKNOWABLE"
echo "$WAIT_UNKNOWABLE" | grep -q "UNKNOWABLE" \
  || { echo "FAIL: a wait for an unbound row must be UNKNOWABLE, never ABSENT"; exit 1; }
echo "$WAIT_UNKNOWABLE" | grep -q "scroll:" \
  || { echo "FAIL: the unknowable verdict must name the scroll travel that clouds it"; exit 1; }
# An unknowable must hand back a tactic, not just a complaint.
echo "$WAIT_UNKNOWABLE" | grep -q "next: act scroll-to --test-id list.item40" \
  || { echo "FAIL: the unknowable verdict must suggest scroll-to for the row"; exit 1; }
# exit 4, distinct from the 3 an `absent` produces.
set +e
R act wait --package "$PKG" --for '#list.item40' --timeout 1500 --strict >/dev/null
WAIT_RC_UNKNOWABLE=$?
set -e
[ "$WAIT_RC_UNKNOWABLE" -eq 4 ] \
  || { echo "FAIL: --strict on an unknowable wait exited $WAIT_RC_UNKNOWABLE, expected 4 (not 3)"; exit 1; }
# `act scroll-to` closes the gap: swipe the container until the selector resolves
# INSIDE it, then confirm the position stopped moving before reporting it. That
# settle step is the whole contract — a flinging list made the first
# implementation report a point that was already stale by the next command.
SCROLLED="$(R act scroll-to --package "$PKG" --test-id list.item40)"
echo "$SCROLLED"
echo "$SCROLLED" | grep -q "found=1" \
  || { echo "FAIL: scroll-to did not bring list.item40 into view"; exit 1; }
echo "$SCROLLED" | grep -q "settled=1" \
  || { echo "FAIL: scroll-to reported a position it could not confirm had stopped moving"; exit 1; }
echo "$SCROLLED" | grep -q "container=list.rows" \
  || { echo "FAIL: scroll-to should have picked the RecyclerView as the container"; exit 1; }
# The point it reported must still be usable by the very next command.
R act tap --package "$PKG" --test-id list.item40 >/dev/null
wait_compact "$PKG" "Picked row 40"
# A selector nothing in the list can satisfy must fail LOUDLY, and say the
# container ran out of travel rather than pretending it might still appear.
NOPE="$(R act scroll-to --package "$PKG" --test-id list.item999 2>&1 || true)"
echo "$NOPE" | grep -qE "reached the end|gave up after" \
  || { echo "FAIL: scroll-to must report exhaustion for an absent row: $NOPE"; exit 1; }

echo "== COMPOSE semantics (testTag, TextField, Dialog window, View interop) =="
# Reticle synthesizes no view per composable: a composable is addressable only
# through the SemanticsNode tree that also backs platform accessibility, read
# reflectively by ComposeSemanticsBridge. That bridge shipped with no scenario at
# all — this is its first end-to-end coverage.
open_scenario scenario.compose compose.payButton
R ui report --package "$PKG" --output "$TMP/compose"
COMPOSE_COMPACT="$(R ui compact "$TMP/compose/snapshot.json")"
echo "$COMPOSE_COMPACT"
echo "$COMPOSE_COMPACT" | grep -q "compose.status" \
  || { echo "FAIL: expected composeSemantics nodes (compose.status) in the tree"; exit 1; }
# Every captured composable must carry a usable frame; a semantics node with no
# geometry is not a movement target.
/usr/bin/python3 - "$TMP/compose/snapshot.json" <<'PY' || exit 1
import json, sys
nodes = json.load(open(sys.argv[1]))["nodes"].values()
tagged = [n for n in nodes if n.get("kind") == "composeSemantics" and n.get("testId")]
if not tagged:
    print("FAIL: no tagged composeSemantics nodes captured"); sys.exit(1)
for n in tagged:
    f = n.get("frame")
    if not f or f["width"] <= 0 or f["height"] <= 0:
        print(f"FAIL: composeSemantics node {n['testId']} has no usable frame: {f}"); sys.exit(1)
PY
# Style evidence, and specifically the Compose half of it. Semantics carries NO
# style of its own, so a Compose screen used to answer none of the questions a
# design asks while the identical View screen answered all of them. Text style now
# comes from the GetTextLayoutResult action's TextStyle — reflective, so a Compose
# release that renames or re-mangles a getter breaks it silently unless asserted
# here. `textLayout` in the output is the proof that path ran, and the
# draw-modifier gap is the proof the unreadable half declares itself.
COMPOSE_STYLE="$(R ui style "$TMP/compose/snapshot.json")"
echo "$COMPOSE_STYLE" | head -30
echo "$COMPOSE_STYLE" | grep -q "\[textLayout\]" \
  || { echo "FAIL: no textLayout channel — the Compose TextStyle reflection produced nothing"; exit 1; }
echo "$COMPOSE_STYLE" | grep -qE "textSize +[0-9.]+px \| [0-9.]+dp \| [0-9.]+sp +\[textLayout\]" \
  || { echo "FAIL: expected a Compose textSize in px|dp|sp via textLayout"; exit 1; }
echo "$COMPOSE_STYLE" | grep -qE "fontWeight +[0-9]+ +\[textLayout\]" \
  || { echo "FAIL: expected a Compose fontWeight via textLayout"; exit 1; }
echo "$COMPOSE_STYLE" | grep -q "! backgroundColor  unreadable: compose-draw-modifier" \
  || { echo "FAIL: a Compose draw-modifier gap must declare itself, not be absent"; exit 1; }
echo "$COMPOSE_STYLE" | grep -q "fontScale=[0-9]" \
  || { echo "FAIL: expected a probed fontScale (got 'unprobed')"; exit 1; }
# A testTag must resolve to a tap that lands (state flips Idle -> Paid!).
R act tap --package "$PKG" --test-id compose.payButton >/dev/null
wait_compact "$PKG" "Paid!"
# `act type` into a composable TextField, not a View.
R act type --package "$PKG" --test-id compose.codeField --text "246813" >/dev/null
wait_compact "$PKG" "Code: 246813"
R act hide-keyboard --package "$PKG" >/dev/null
# An AndroidView interop child is a classic View inside the Compose tree; its
# identity comes from the View tag, not from a semantics tag.
R act tap --package "$PKG" --test-id compose.interopButton >/dev/null
wait_compact "$PKG" "Interop tapped"
# A Compose Dialog is its OWN window with its own Compose host — the multi-window
# walk has to find a second semantics owner, not just the activity's.
R act tap --package "$PKG" --test-id compose.dialogTrigger >/dev/null
wait_compact "$PKG" "composeDialog.title"
R act tap --package "$PKG" --test-id composeDialog.confirm >/dev/null
wait_compact "$PKG" "Confirmed"
# Sub-regions inside ONE Compose text node: its links are AnnotatedString ranges,
# not child nodes, so they are recovered from the semantics config (Text ->
# getLinkAnnotations) plus the GetTextLayoutResult action's laid-out geometry.
# Each link must resolve to its OWN rect — tapping "Terms" must not open "Privacy".
R ui report --package "$PKG" --output "$TMP/compose-links"
COMPOSE_REGIONS="$(R ui regions "$TMP/compose-links/snapshot.json")"
echo "$COMPOSE_REGIONS"
echo "$COMPOSE_REGIONS" | grep -q 'span "Terms" -> terms' \
  || { echo "FAIL: expected a span region for the Compose text link 'Terms'"; exit 1; }
echo "$COMPOSE_REGIONS" | grep -q 'span "Privacy" -> privacy' \
  || { echo "FAIL: expected a span region for the Compose text link 'Privacy'"; exit 1; }
R act tap --package "$PKG" --test-id compose.agreement --region "Terms" >/dev/null
wait_compact "$PKG" "opened Terms"
R act tap --package "$PKG" --test-id compose.agreement --region "Privacy" >/dev/null
wait_compact "$PKG" "opened Privacy"
COMPOSE_LOGS="$(R debug logs --package "$PKG")"
echo "$COMPOSE_LOGS" | grep -q "compose_paid" \
  || { echo "FAIL: expected compose_paid in the app log bridge"; exit 1; }
echo "$COMPOSE_LOGS" | grep -q "compose_dialog_confirmed" \
  || { echo "FAIL: expected compose_dialog_confirmed in the app log bridge"; exit 1; }

echo "== CANVAS CONTROL regions (virtual a11y nodes + touch delegate) =="
# A self-drawn control has no child views, so its segments exist only as virtual
# accessibility nodes; a touch delegate's forwarded rect exists only in the
# delegate. Both channels were shipped but never exercised, and both were broken:
# the virtual-node probe assumed dense 0-based ids (so a control with stable ids
# yielded nothing), and the delegate rect came from a `TouchDelegate.mBounds`
# reflection the platform blocks (api=max-target-o) for anything targeting O+.
open_scenario scenario.canvasControl canvas.segments
R ui report --package "$PKG" --output "$TMP/canvas"
CANVAS_REGIONS="$(R ui regions "$TMP/canvas/snapshot.json")"
echo "$CANVAS_REGIONS"
echo "$CANVAS_REGIONS" | grep -q 'a11yVirtual "Monthly"' \
  || { echo "FAIL: expected virtual a11y regions from the dense-id canvas control"; exit 1; }
echo "$CANVAS_REGIONS" | grep -q 'a11yVirtual "A3"' \
  || { echo "FAIL: expected virtual a11y regions from the STABLE-id canvas control"; exit 1; }
echo "$CANVAS_REGIONS" | grep -q "touchDelegate" \
  || { echo "FAIL: expected a touchDelegate region for the delegate-expanded icon"; exit 1; }
# The delegate rect must be the expanded row, not the icon's own 20x20 frame.
/usr/bin/python3 - "$TMP/canvas/snapshot.json" <<'PY' || exit 1
import json, sys
nodes = json.load(open(sys.argv[1]))["nodes"].values()
host = next(n for n in nodes if n.get("testId") == "canvas.iconHost")
icon = next(n for n in nodes if n.get("testId") == "canvas.icon")
rect = next(r["rects"][0] for r in host["regions"] if r["source"] == "touchDelegate")
if rect["width"] <= icon["frame"]["width"] * 2:
    print(f"FAIL: touchDelegate rect {rect} is not wider than the icon {icon['frame']}")
    sys.exit(1)
PY
# Taps driven from the recovered rects. The control hit-tests privately and the
# delegate rect's center is far from the icon, so a wrong rect silently does
# nothing — the status text is the only honest proof.
R act tap --package "$PKG" --test-id canvas.segments --region "Monthly" >/dev/null
wait_compact "$PKG" "Segment: Monthly"   # tap on the dense-id virtual node did not land otherwise
R act tap --package "$PKG" --test-id canvas.seats --region "A3" >/dev/null
wait_compact "$PKG" "Seat: A3"   # tap on the stable-id virtual node did not land otherwise
# `--region touchDelegate` addresses a channel that carries no label (a delegate's
# target is only resolvable through an a11y connection, which an in-process agent
# lacks), so the source name is the selector.
R act tap --package "$PKG" --test-id canvas.iconHost --region touchDelegate >/dev/null
wait_compact "$PKG" "Icon tapped"   # tap inside the forwarded touch-delegate rect never reached the icon otherwise
CANVAS_LOGS="$(R debug logs --package "$PKG")"
echo "$CANVAS_LOGS" | grep -q "canvas_segment_picked" \
  || { echo "FAIL: expected canvas_segment_picked in the app log bridge"; exit 1; }
echo "$CANVAS_LOGS" | grep -q "canvas_icon_tapped" \
  || { echo "FAIL: expected canvas_icon_tapped in the app log bridge"; exit 1; }

echo "== WEBVIEW DOM =="
# The home row loads the basic checkout fixture; the readiness marker is a
# folded DOM node, so this also proves the WebView loaded and the DOM bridge
# merged into the unified tree before we assert on it. (The richer "complex"
# fixture — shadow DOM, iframe, ARIA — is reachable via the reticle.webScenario
# intent extra; the basic fixture is what the default scenario shows.)
open_scenario scenario.webview web.payButton
R ui report --package "$PKG" --output "$TMP/webview"
WEB_COMPACT="$(R ui compact "$TMP/webview/snapshot.json")"
echo "$WEB_COMPACT" | grep -q "web.payButton" \
  || { echo "FAIL: expected folded domNodes (web.payButton) from the WebView"; exit 1; }
echo "$WEB_COMPACT" | grep -q "web.status" \
  || { echo "FAIL: expected the web.status domNode"; exit 1; }
# Computed CSS is the DOM's style channel, and it must behave DIFFERENTLY from a
# native one: the values keep their own suffixes and are NOT converted, because a
# page's zoom and viewport scaling are not observable from in-process — a px->dp
# division here would be arithmetic on an assumption. Also asserted: a computed
# value sitting at its CSS initial ("auto"/"none"/"0px") is dropped, since
# getComputedStyle answers for every property whether or not the page stated it and
# one node otherwise printed 26 lines that say nothing.
WEB_STYLE="$(R ui style "$TMP/webview/snapshot.json")"
echo "$WEB_STYLE" | grep -A 8 computedStyle | head -12
echo "$WEB_STYLE" | grep -qE "domStyleFontSize +[0-9]+px +\\[computedStyle\\]" \
  || { echo "FAIL: expected a domStyleFontSize via computedStyle"; exit 1; }
echo "$WEB_STYLE" | grep -qE "domStyleFontSize +[0-9.]+px \\| [0-9.]+dp" \
  && { echo "FAIL: a computed CSS length was converted to dp — the page's zoom is not observable"; exit 1; }
echo "$WEB_STYLE" | grep -qE "domStyle\\w+ +(auto|none|static|visible|0px) " \
  && { echo "FAIL: a computed style at its CSS initial value must be dropped, not printed"; exit 1; }
# CSS selector resolution against a folded domNode.
R ui node "$TMP/webview/snapshot.json" --css "#web-pay" >/dev/null \
  || { echo "FAIL: --css lookup on a folded domNode"; exit 1; }
# DOM tap with an observable side effect: #web-pay sets #web-status to
# "Web paid" via its onclick — proof the tap reached the DOM element.
R act tap --package "$PKG" --css "#web-pay" >/dev/null
sleep 1
R ui report --package "$PKG" --output "$TMP/webview-after"
R ui compact "$TMP/webview-after/snapshot.json" | grep -q "Web paid" \
  || { echo "FAIL: DOM tap did not fire #web-pay onclick (web.status never became 'Web paid')"; exit 1; }

echo "== SAME-ORIGIN IFRAME (chained selector + page-offset geometry) =="
# The DOM walk pierces same-origin iframes and accumulates the frame's page
# offset, because frame content coordinates are relative to the FRAME viewport.
# Nothing asserted that offset before, and getting it wrong is silent: the rect
# lands near the top of the page and a coordinate tap hits an unrelated element.
# The complex fixture carries the frame; it is selected by the fixture extra
# (`am start` from shell can start the non-exported activity).
boot_app "$PKG"
"$ADB" -s "$SERIAL" shell am start -n "$PKG/.WebViewScenarioActivity" \
  --es reticle.webScenario complex >/dev/null 2>&1
wait_compact "$PKG" "complex.iframeButton"
R ui report --package "$PKG" --output "$TMP/iframe"
R ui node "$TMP/iframe/snapshot.json" --css "#fixture-frame >>> #iframe-button" >/dev/null \
  || { echo "FAIL: chained selector for same-origin iframe content did not resolve"; exit 1; }
# Geometry: the frame's inner button must sit INSIDE the iframe element's rect. A
# dropped page offset fails this while still producing a plausible-looking rect.
/usr/bin/python3 - "$TMP/iframe/snapshot.json" <<'PY' || exit 1
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
# A COORDINATE tap (not DOM activation, which would pass even with a wrong rect)
# at the reported rect must fire the frame's own onclick.
R act tap --package "$PKG" --css "#fixture-frame >>> #iframe-button" >/dev/null
wait_compact "$PKG" "Frame clicked"
# The shadow-DOM boundary, asserted from BOTH sides on one screen: an OPEN root is
# pierced, a CLOSED one cannot be — `{mode:'closed'}` gives the page itself no
# `shadowRoot` handle, so the traversal script has nothing to walk. The absence is
# the assertion; without it, "no closed-shadow nodes" would just be silence.
SHADOW_COMPACT="$(R ui compact --live --package "$PKG")"
echo "$SHADOW_COMPACT" | grep -q "complex.shadowButton" \
  || { echo "FAIL: an OPEN shadow root must still be pierced"; exit 1; }
echo "$SHADOW_COMPACT" | grep -q "Closed shadow action" \
  && { echo "FAIL: a CLOSED shadow root must not be readable — this would be a wrong claim, not a win"; exit 1; }
# The host element itself is still there: the boundary is the root's content, not
# the element, so the closed widget stays targetable as a plain DOM node.
echo "$SHADOW_COMPACT" | grep -q "complex.closedShadowHost" \
  || { echo "FAIL: the closed shadow HOST element should still be captured"; exit 1; }

echo "== COMPOUND FIELDS: type verifies focus, not dispatch =="
# The shape real forms are built from: the unique id is on the WRAPPER and the
# EditText inside it reuses a generic one. A tap on the wrapper focuses nothing,
# so `type` used to report chars=N into a field that stayed empty.
open_scenario scenario.compoundField compound.firstName
# 1. Targeting the wrapper: exactly one focusable input inside it, so `type`
# re-aims once and says so, rather than typing into the void.
COMPOUND_TYPE="$(R act type --package "$PKG" --test-id compound.firstName --text "Ada")"
echo "$COMPOUND_TYPE"
echo "$COMPOUND_TYPE" | grep -q "focusLanded=" \
  || { echo "FAIL: type must report where focus landed, got: $COMPOUND_TYPE"; exit 1; }
echo "$COMPOUND_TYPE" | grep -Eq "focusLanded=(self|descendant)" \
  || { echo "FAIL: type into a compound wrapper must land in its input, got: $COMPOUND_TYPE"; exit 1; }
sleep 1
R ui report --package "$PKG" --output "$TMP/compound-typed"
R ui compact "$TMP/compound-typed/snapshot.json" | grep -q "Ada" \
  || { echo "FAIL: the text did not reach the nested EditText"; exit 1; }
# The focused field is marked in compact — "where would text go" is not inferable
# from a rect, and the wrapper is `tappable` while taking no focus at all.
R ui compact "$TMP/compound-typed/snapshot.json" | grep -q "focused" \
  || { echo "FAIL: compact must mark the focused node"; exit 1; }
# 2. Two inputs under one wrapper is a GUESS, and must be refused rather than
# silently filling one of them.
set +e
AMBIGUOUS="$(R act type --package "$PKG" --test-id compound.ambiguous --text "07" 2>&1)"
AMBIGUOUS_RC=$?
set -e
[ "$AMBIGUOUS_RC" -ne 0 ] \
  || { echo "FAIL: type into a wrapper with two inputs must be refused, got: $AMBIGUOUS"; exit 1; }
echo "$AMBIGUOUS" | grep -q "did not focus a text field" \
  || { echo "FAIL: the refusal must say focus never landed; got: $AMBIGUOUS"; exit 1; }

echo "== LOGIN keyboard trap =="
open_scenario scenario.login login.codeField
# Focus the code field so the soft keyboard comes up.
R act tap --package "$PKG" --test-id login.codeField >/dev/null
sleep 1
TYPE_OUT="$(R act type --package "$PKG" --test-id login.codeField --text "123456")"
echo "$TYPE_OUT"
echo "$TYPE_OUT" | grep -Eq "keyboardVisible=(1|true)" \
  || { echo "FAIL: act type did not report the keyboard (is show_ime_with_hard_keyboard set?)"; exit 1; }
R ui report --package "$PKG" --output "$TMP/login"
LOGIN_COMPACT="$(R ui compact "$TMP/login/snapshot.json")"
echo "$LOGIN_COMPACT"
echo "$LOGIN_COMPACT" | grep -q "keyboard: visible" \
  || { echo "FAIL: compact must lead with 'keyboard: visible' while the keyboard is up"; exit 1; }
echo "$LOGIN_COMPACT" | grep "login.submitButton" | grep -q "occluded-by:keyboard" \
  || { echo "FAIL: the covered submit button must be marked occluded-by:keyboard"; exit 1; }
# A wait for the covered button must RESOLVE — it is targetable, and the very
# next `act` resolves it the same way — while carrying the occlusion as a caveat
# with the command that clears it. Downgrading this to a failure would conflate
# "can the next act target it" with "can the user see it"; the earlier, dropped
# `wait --for appears` proposal made exactly that mistake by testing isVisible.
WAIT_OCCLUDED="$(R act wait --package "$PKG" --for '#login.submitButton' --timeout 3000)"
echo "$WAIT_OCCLUDED"
echo "$WAIT_OCCLUDED" | grep -q "RESOLVED" \
  || { echo "FAIL: a keyboard-covered but targetable button must still be RESOLVED"; exit 1; }
echo "$WAIT_OCCLUDED" | grep -q "caveats: occluded-by:keyboard" \
  || { echo "FAIL: the resolved wait must carry the occlusion as a caveat"; exit 1; }
echo "$WAIT_OCCLUDED" | grep -q "next: act hide-keyboard" \
  || { echo "FAIL: the occlusion caveat must suggest hide-keyboard"; exit 1; }
# Dismiss in-process and confirm the settled state round-trips.
HIDE_OUT="$(R act hide-keyboard --package "$PKG")"
echo "$HIDE_OUT"
echo "$HIDE_OUT" | grep -Eq "wasVisible=(1|true)" \
  || { echo "FAIL: hide-keyboard must report wasVisible"; exit 1; }
R ui report --package "$PKG" --output "$TMP/login-hidden"
LOGIN_AFTER="$(R ui compact "$TMP/login-hidden/snapshot.json")"
echo "$LOGIN_AFTER" | grep -q "keyboard: hidden" \
  || { echo "FAIL: compact must report 'keyboard: hidden' after hide-keyboard"; exit 1; }
echo "$LOGIN_AFTER" | grep "login.submitButton" | grep -q "occluded-by" \
  && { echo "FAIL: submit button still occluded after hide-keyboard"; exit 1; }
# The freed button must now actually work.
R act tap --package "$PKG" --test-id login.submitButton >/dev/null
sleep 1
R ui report --package "$PKG" --output "$TMP/login-done"
R ui compact "$TMP/login-done/snapshot.json" | grep -q "Logged in: 123456" \
  || { echo "FAIL: submit after hide-keyboard did not log in"; exit 1; }

echo "== LOGIN: type --submit editor action =="
# Re-open and drive the OTP one-shot: type + Done fires the field's editor
# action (onEditorAction -> submitCode), no separate submit tap.
open_scenario scenario.login login.codeField
R act tap --package "$PKG" --test-id login.codeField >/dev/null
sleep 1
R act type --package "$PKG" --test-id login.codeField --text "654321" --submit >/dev/null
sleep 1
R ui report --package "$PKG" --output "$TMP/login-submit"
R ui compact "$TMP/login-submit/snapshot.json" | grep -q "Logged in: 654321" \
  || { echo "FAIL: type --submit did not fire the field's Done editor action"; exit 1; }

echo "== SYSTEM DIALOG (AlertDialog window) =="
# An AlertDialog is a *separate* WindowManagerGlobal root over the activity. This
# is the multi-window recognition case: the capture must surface the dialog's own
# content (title / message / buttons) AND mark the background control behind it
# occluded by the dialog window — the window-vs-window occlusion path that no
# other scenario exercises.
open_scenario scenario.dialog dialog.trigger
# Raise the dialog, then wait until its own window has actually drawn.
R act tap --package "$PKG" --test-id dialog.trigger >/dev/null
wait_compact "$PKG" "alertTitle"
R ui report --package "$PKG" --output "$TMP/dialog"
DIALOG_COMPACT="$(R ui compact "$TMP/dialog/snapshot.json")"
echo "$DIALOG_COMPACT"
echo "$DIALOG_COMPACT" | grep -q "Delete account?" \
  || { echo "FAIL: dialog title 'Delete account?' not captured (multi-window walk)"; exit 1; }
echo "$DIALOG_COMPACT" | grep -q "This action cannot be undone." \
  || { echo "FAIL: dialog message not captured"; exit 1; }
echo "$DIALOG_COMPACT" | grep -q 'button "Delete"' \
  || { echo "FAIL: dialog positive button 'Delete' not captured"; exit 1; }
echo "$DIALOG_COMPACT" | grep -q 'button "Cancel"' \
  || { echo "FAIL: dialog negative button 'Cancel' not captured"; exit 1; }
# The distinctive signal: the background trigger is behind the dialog window, so
# it must be reported occluded-by the dialog root (a tap there would be swallowed).
echo "$DIALOG_COMPACT" | grep "dialog.trigger" | grep -q "occluded-by" \
  || { echo "FAIL: background dialog.trigger must be marked occluded-by the dialog window"; exit 1; }
# Confirm the dialog button lands: tapping Delete flips dialog.status -> "Deleted"
# and dismisses the dialog. --verify watches the background status node across the
# dialog dismissal; --trace-output writes the evidence package.
DIALOG_VERIFY="$(R act tap --package "$PKG" --test-id button1 \
  --verify 'testId=dialog.status' --trace-output "$TMP/dialog-trace")"
echo "$DIALOG_VERIFY"
echo "$DIALOG_VERIFY" | grep -q "Deleted" \
  || { echo "FAIL: --verify did not record dialog.status changing to Deleted"; exit 1; }
sleep 1
R ui report --package "$PKG" --output "$TMP/dialog-done"
DIALOG_AFTER="$(R ui compact "$TMP/dialog-done/snapshot.json")"
echo "$DIALOG_AFTER" | grep -q "Deleted" \
  || { echo "FAIL: tapping Delete did not land (dialog.status never became Deleted)"; exit 1; }
echo "$DIALOG_AFTER" | grep -q "alertTitle" \
  && { echo "FAIL: dialog window still present after Delete (it should be dismissed)"; exit 1; }
DIALOG_TRACE="$(find "$TMP/dialog-trace" -name trace.json | head -1)"
[ -n "$DIALOG_TRACE" ] && grep -q "Deleted" "$DIALOG_TRACE" \
  || { echo "FAIL: dialog trace.json diff did not record the dialog.status change"; exit 1; }
# App-authored log bridge: the dialog logs must surface through /logs.
DIALOG_LOGS="$(R debug logs --package "$PKG")"
echo "$DIALOG_LOGS" | grep -q "dialog_opened" \
  || { echo "FAIL: expected dialog_opened in the app log bridge"; exit 1; }
echo "$DIALOG_LOGS" | grep -q "dialog_confirmed" \
  || { echo "FAIL: expected dialog_confirmed in the app log bridge"; exit 1; }

echo "== LOTTIE DIALOG (native, with a real Lottie animation view) =="
# A native AlertDialog whose custom view hosts a real LottieAnimationView. The
# animation is an opaque surface (no text); this asserts the recognizable
# elements around it — title, message, button — are still captured with correct
# content, and that the Lottie view itself is located as a node with a frame.
open_scenario scenario.lottieDialog lottieDialog.trigger
R act tap --package "$PKG" --test-id lottieDialog.trigger >/dev/null
wait_compact "$PKG" "Please wait"
R ui report --package "$PKG" --output "$TMP/lottie"
LOTTIE_COMPACT="$(R ui compact "$TMP/lottie/snapshot.json")"
echo "$LOTTIE_COMPACT"
echo "$LOTTIE_COMPACT" | grep -q "Please wait" \
  || { echo "FAIL: lottie dialog title 'Please wait' not captured"; exit 1; }
echo "$LOTTIE_COMPACT" | grep -q "Processing your request." \
  || { echo "FAIL: lottie dialog message not captured"; exit 1; }
echo "$LOTTIE_COMPACT" | grep "lottieDialog.animation" | grep -q "image" \
  || { echo "FAIL: the Lottie animation view must be located as an image node with a frame"; exit 1; }
echo "$LOTTIE_COMPACT" | grep -q 'button "Done"' \
  || { echo "FAIL: lottie dialog 'Done' button not captured"; exit 1; }
echo "$LOTTIE_COMPACT" | grep "lottieDialog.trigger" | grep -q "occluded-by" \
  || { echo "FAIL: background trigger must be occluded-by the lottie dialog window"; exit 1; }
LOTTIE_VERIFY="$(R act tap --package "$PKG" --test-id button1 --verify 'testId=lottieDialog.status')"
echo "$LOTTIE_VERIFY" | grep -q "Done" \
  || { echo "FAIL: tapping Done did not flip lottieDialog.status to Done"; exit 1; }
R debug logs --package "$PKG" | grep -q "lottie_dialog_confirmed" \
  || { echo "FAIL: expected lottie_dialog_confirmed in the app log bridge"; exit 1; }

echo "== WEB LOTTIE DIALOG (lottie-web modal inside a WebView) =="
# A modal rendered in the WebView by lottie-web. Asserts the DOM bridge folds the
# modal's elements (dialog role, animation container, title, message, button)
# into the unified tree with content + frames while an animated <svg> plays.
open_scenario scenario.webLottieDialog webLottie.trigger
R act tap --package "$PKG" --css "#open-lottie" >/dev/null
sleep 2
R ui report --package "$PKG" --output "$TMP/web-lottie"
WEB_LOTTIE="$(R ui compact "$TMP/web-lottie/snapshot.json")"
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
# The DOM button must land: #lottie-done sets #web-status to "Done". POLL for it
# rather than taking one snapshot: the DOM bridge caps its evaluateJavascript wait
# at 750ms, and while lottie-web animates on a software-GPU emulator that budget
# can lapse — the WebView then degrades to an opaque node (its honest L0), so a
# single capture can miss the whole DOM and read as "the tap didn't land".
R act tap --package "$PKG" --css "#lottie-done" >/dev/null
wait_compact "$PKG" "Done"
R ui report --package "$PKG" --output "$TMP/web-lottie-done"

echo "== SYSTEM PERMISSION PROMPT (out of process: focus evidence) =="
# The one on-screen thing an in-process agent structurally CANNOT capture: the
# prompt belongs to the permission controller, another process, so it is in no
# window of this app and no node of this tree. Verified during this work:
# `mCurrentFocus=com.google.android.permissioncontroller/...GrantPermissionsActivity`
# while the capture still listed every control as tappable. Reticle cannot show the
# prompt; it CAN report that this app's window lost focus, which is a fact and
# enough for an agent to stop instead of tapping into a void.
"$ADB" -s "$SERIAL" shell pm revoke "$PKG" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
open_scenario scenario.permission permission.trigger
if R ui compact --live --package "$PKG" | head -1 | grep -q "UNFOCUSED"; then
  echo "FAIL: the app should hold focus before the prompt is raised"; exit 1
fi
R act tap --package "$PKG" --test-id permission.trigger >/dev/null
wait_compact "$PKG" "UNFOCUSED"
# The prompt's own content must be absent — the boundary, stated as an assertion so
# nobody later mistakes silence for capture.
R ui report --package "$PKG" --output "$TMP/permission"
/usr/bin/python3 - "$TMP/permission/snapshot.json" <<'PYEOF' || exit 1
import json, sys
snap = json.load(open(sys.argv[1]))
for node in snap["nodes"].values():
    name = (node.get("typeName") or "").lower()
    if "permissioncontroller" in name:
        print(f"FAIL: another process's node leaked into the tree: {name}")
        sys.exit(1)
if snap["screen"].get("windowFocused") is not False:
    print("FAIL: screen.windowFocused should be false while another window has focus")
    sys.exit(1)
PYEOF
# The strongest case for the three-state outcome. permission.status genuinely has
# not changed — but the reason is that nobody has answered a prompt this process
# cannot see, so `absent` would be a lie an agent would act on ("the app never
# grants the permission"). It must be UNKNOWABLE, with the lost focus named.
WAIT_UNFOCUSED="$(R act wait --package "$PKG" --for '#permission.status' --text 'granted' --timeout 3000)"
echo "$WAIT_UNFOCUSED"
echo "$WAIT_UNFOCUSED" | grep -q "UNKNOWABLE" \
  || { echo "FAIL: a wait behind another process's window must be UNKNOWABLE, never ABSENT"; exit 1; }
echo "$WAIT_UNFOCUSED" | grep -q "reasons:.*window-unfocused" \
  || { echo "FAIL: the unknowable verdict must name the lost window focus"; exit 1; }
set +e
R act wait --package "$PKG" --for '#permission.status' --text 'granted' --timeout 1500 --strict >/dev/null
WAIT_RC_UNFOCUSED=$?
set -e
[ "$WAIT_RC_UNFOCUSED" -eq 4 ] \
  || { echo "FAIL: --strict behind a foreign window exited $WAIT_RC_UNFOCUSED, expected 4"; exit 1; }
# Dismissing restores focus, and the evidence clears with it.
"$ADB" -s "$SERIAL" shell input keyevent KEYCODE_BACK >/dev/null 2>&1 || true
sleep 2
if R ui compact --live --package "$PKG" | head -1 | grep -q "UNFOCUSED"; then
  echo "FAIL: focus evidence must clear once the prompt is gone"; exit 1
fi

echo "== WEB JS DIALOG (alert() blocks the page's JS thread) =="
# `alert()` is not one more dialog: it blocks the page's JS thread until the app
# dismisses it, so while the modal is up the DOM bridge's evaluateJavascript can
# never call back. Three things must hold — the capture must not hang, the DOM must
# degrade to the honest L0 (an opaque WebView node) instead of reporting stale
# nodes as if they were live, and the native modal must still be recognized.
open_scenario scenario.webJsDialog jsDialog.alertButton
R ui report --package "$PKG" --output "$TMP/js-dialog"
R ui compact "$TMP/js-dialog/snapshot.json" | grep -q "jsDialog.status" \
  || { echo "FAIL: expected the page's DOM nodes before the alert"; exit 1; }
# Raise the alert from the page.
R act tap --package "$PKG" --css "#js-alert" >/dev/null
wait_compact "$PKG" "Message from the page"
# The capture completes (a hang would blow the 60s wait above) and the native
# modal's own content is captured.
START="$(date +%s)"
R ui report --package "$PKG" --output "$TMP/js-dialog-open"
ELAPSED=$(( $(date +%s) - START ))
[ "$ELAPSED" -lt 20 ] \
  || { echo "FAIL: capture took ${ELAPSED}s with a JS modal up — it should degrade, not block"; exit 1; }
JS_OPEN="$(R ui compact "$TMP/js-dialog-open/snapshot.json")"
echo "$JS_OPEN"
echo "$JS_OPEN" | grep -q "Payment failed" \
  || { echo "FAIL: the native JS-alert modal's message was not captured"; exit 1; }
# The DOM is gone rather than stale: the WebView is back to an opaque node.
echo "$JS_OPEN" | grep -q "jsDialog.status" \
  && { echo "FAIL: DOM nodes must NOT be reported while the JS thread is blocked"; exit 1; }
# ...and the absence must be LABELLED. "No DOM nodes" and "this web view is empty"
# are otherwise the same observation; the host node carries dom:unavailable so an
# agent can tell a blocked bridge from an empty page.
echo "$JS_OPEN" | grep -q "dom:unavailable" \
  || { echo "FAIL: the web view must report dom:unavailable while the DOM is unreadable"; exit 1; }
# A `--css` wait cannot be answered at all while the bridge is blocked, so it must
# be UNKNOWABLE with dom:unavailable as the reason — not `absent`, which would
# read as "the page does not contain that element".
WAIT_DOM="$(R act wait --package "$PKG" --for 'css=#js-alert' --timeout 3000)"
echo "$WAIT_DOM"
echo "$WAIT_DOM" | grep -q "UNKNOWABLE" \
  || { echo "FAIL: a css wait with an unreadable DOM must be UNKNOWABLE, never ABSENT"; exit 1; }
echo "$WAIT_DOM" | grep -q "dom:unavailable" \
  || { echo "FAIL: the unknowable css wait must name dom:unavailable as its reason"; exit 1; }
# Dismissing releases the JS thread: the page's own onclick continues, and the DOM
# bridge starts answering again.
R act tap --package "$PKG" --label "OK" >/dev/null
wait_compact "$PKG" "Alert dismissed"
JS_LOGS="$(R debug logs --package "$PKG")"
echo "$JS_LOGS" | grep -q "web_js_alert_shown" \
  || { echo "FAIL: expected web_js_alert_shown in the app log bridge"; exit 1; }
echo "$JS_LOGS" | grep -q "web_js_alert_dismissed" \
  || { echo "FAIL: expected web_js_alert_dismissed in the app log bridge"; exit 1; }

echo "== WEB COMPONENT DIALOG (custom element + open shadow root) =="
# A modal built as a Web Component whose content lives in an OPEN shadow root.
# Asserts Reticle pierces the shadow boundary and folds the modal's elements into
# the unified tree with content + frames, and that a shadow-piercing tap lands.
open_scenario scenario.webComponentDialog webComponent.trigger
R act tap --package "$PKG" --css "#open-wc" >/dev/null
sleep 1
R ui report --package "$PKG" --output "$TMP/web-comp"
WEB_COMP="$(R ui compact "$TMP/web-comp/snapshot.json")"
echo "$WEB_COMP"
echo "$WEB_COMP" | grep "webComponent.title" | grep -q "Delete item?" \
  || { echo "FAIL: shadow-DOM title not folded in (shadow piercing)"; exit 1; }
echo "$WEB_COMP" | grep "webComponent.message" | grep -q "remove it permanently." \
  || { echo "FAIL: shadow-DOM message not folded in"; exit 1; }
echo "$WEB_COMP" | grep "webComponent.cancel" | grep -q 'button "Cancel"' \
  || { echo "FAIL: shadow-DOM Cancel button not folded in"; exit 1; }
echo "$WEB_COMP" | grep "webComponent.confirm" | grep -q 'button "Delete"' \
  || { echo "FAIL: shadow-DOM Delete button not folded in"; exit 1; }
# The shadow-DOM button must be actionable: tapping it sets #wc-status to
# "Deleted". Tap by the folded testId (frame-based) rather than a `>>>`
# shadow-piercing CSS selector — on Android the piercing selector matches the
# node but the helper can't resolve a coordinate tap point through it, whereas
# the folded node's own frame taps fine. (iOS drives the same button via DOM
# `act activate`, which needs no coordinate.)
R act tap --package "$PKG" --test-id webComponent.confirm >/dev/null
sleep 1
R ui report --package "$PKG" --output "$TMP/web-comp-done"
R ui compact "$TMP/web-comp-done/snapshot.json" | grep "webComponent.status" | grep -q "Deleted" \
  || { echo "FAIL: tapping the shadow-DOM Delete button did not update the status"; exit 1; }

echo "== LOTTIE-ONLY DIALOG (whole dialog baked into one Lottie) =="
# The title / message / both buttons are Lottie layers, not views — the plain
# tree sees one opaque node. The Lottie bridge introspects the parsed composition
# and surfaces each text layer as a `lottie` region (content + screen rect). This
# asserts those elements are recovered, and that a tap at a recovered position
# fires the app's in-canvas hit-test callback (there are no child views to click).
open_scenario scenario.lottieOnlyDialog lottieOnly.trigger
R act tap --package "$PKG" --test-id lottieOnly.trigger >/dev/null
# The Lottie composition loads asynchronously; poll until the bridge's regions
# appear rather than trusting a fixed sleep.
for _ in $(seq 1 15); do
  R ui report --package "$PKG" --output "$TMP/lottie-only" >/dev/null 2>&1
  R ui regions "$TMP/lottie-only/snapshot.json" 2>/dev/null | grep -q 'lottie "Delete"' && break
  sleep 1
done
LOTTIE_REGIONS="$(R ui regions "$TMP/lottie-only/snapshot.json")"
echo "$LOTTIE_REGIONS"
echo "$LOTTIE_REGIONS" | grep -q 'lottie "Delete item?"' \
  || { echo "FAIL: Lottie title not recovered from the composition"; exit 1; }
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
R act tap --package "$PKG" --point "$DELETE_PT" >/dev/null
sleep 1
R ui report --package "$PKG" --output "$TMP/lottie-only-done"
R ui compact "$TMP/lottie-only-done/snapshot.json" | grep "lottieOnly.status" | grep -q "Deleted" \
  || { echo "FAIL: tapping the recovered Lottie 'Delete' position did not fire the in-canvas callback"; exit 1; }
R debug logs --package "$PKG" | grep -q "lottie_only_choice" \
  || { echo "FAIL: expected lottie_only_choice in the app log bridge"; exit 1; }

echo "== SCREENSHOT DEGRADE (SurfaceView + FLAG_SECURE) =="
# The two ways a screenshot lies, and they are exact complements — measured here,
# not assumed:
#   - a SurfaceView draws into its OWN surface (composited by SurfaceFlinger), so the
#     agent's in-process Canvas walk leaves a transparent hole exactly there
#     (rgba 0,0,0,0) while `adb exec-out screencap` shows the magenta surface;
#   - FLAG_SECURE is the mirror: the in-process capture is unaffected while the
#     device-level capture comes back fully blanked (rgba 0,0,0,255).
# Either failure is SILENT by default, and a blank rect reads as "the app drew
# nothing there" — the same trap `dom:unavailable` closed for the DOM. So each
# absence must be LABELLED: `pixels:unavailable` on the node, `screencap:blank` on
# the window, and a `degraded:` line on the picture that is actually missing them.
# This asserts the labels AND the pixels behind them, so the labels can never drift
# into being decorative.
open_scenario scenario.screenshotDegrade degrade.surface
# Read a single pixel: crop with sips (native, fast), downsample to 1x1, then decode
# that trivial PNG. Pure-python unfiltering of a full-screen PNG would be far slower.
PX_PY="$TMP/px.py"
cat > "$PX_PY" <<'PYEOF'
import sys, zlib, struct
data = open(sys.argv[1], 'rb').read()
pos, idat, ct = 8, b'', 6
while pos < len(data):
    ln, typ = struct.unpack('>I4s', data[pos:pos+8]); pos += 8
    chunk = data[pos:pos+ln]; pos += ln + 4
    if typ == b'IHDR': ct = struct.unpack('>IIBB', chunk[:10])[3]
    elif typ == b'IDAT': idat += chunk
    elif typ == b'IEND': break
ch = {0: 1, 2: 3, 4: 2, 6: 4}[ct]
px = list(zlib.decompress(idat)[1:1 + ch])   # 1x1: one filter byte, then the pixel
while len(px) < 4: px.append(255)
print(",".join(str(v) for v in px))
PYEOF
pixel_at() { # png x y -> "r,g,b,a"
  sips -c 40 40 --cropOffset "$3" "$2" "$1" --out "$TMP/px-crop.png" >/dev/null 2>&1
  sips -z 1 1 "$TMP/px-crop.png" --out "$TMP/px-tiny.png" >/dev/null 2>&1
  /usr/bin/python3 "$PX_PY" "$TMP/px-tiny.png"
}
SURFACE_RECT="$(R ui compact --live --package "$PKG" | grep "degrade.surface")"
echo "$SURFACE_RECT"
echo "$SURFACE_RECT" | grep -q "pixels:unavailable" \
  || { echo "FAIL: the SurfaceView must be marked pixels:unavailable"; exit 1; }
R ui screenshot --package "$PKG" --output "$TMP/degrade-agent.png" | tee "$TMP/degrade-agent.txt"
grep -q "degraded: degrade.surface" "$TMP/degrade-agent.txt" \
  || { echo "FAIL: the screenshot must report the region it could not capture"; exit 1; }
"$ADB" -s "$SERIAL" exec-out screencap -p > "$TMP/degrade-device.png"
AGENT_PX="$(pixel_at "$TMP/degrade-agent.png" 400 500)"
DEVICE_PX="$(pixel_at "$TMP/degrade-device.png" 400 500)"
echo "surface pixel: agent=$AGENT_PX device=$DEVICE_PX"
[ "$AGENT_PX" = "0,0,0,0" ] \
  || { echo "FAIL: the in-process capture should have a transparent hole over the SurfaceView, got $AGENT_PX"; exit 1; }
echo "$DEVICE_PX" | grep -q "^255,0,255" \
  || { echo "FAIL: the device capture should show the magenta surface, got $DEVICE_PX"; exit 1; }
# FLAG_SECURE: now the DEVICE capture is the blind one, and it must say so too.
R act tap --package "$PKG" --test-id degrade.secureToggle >/dev/null
wait_compact "$PKG" "Secure: on"
R ui screenshot --package "$PKG" --output "$TMP/degrade-agent-secure.png" | tee "$TMP/degrade-secure.txt"
grep -q "FLAG_SECURE window" "$TMP/degrade-secure.txt" \
  || { echo "FAIL: a FLAG_SECURE window must be reported alongside the picture"; exit 1; }
"$ADB" -s "$SERIAL" exec-out screencap -p > "$TMP/degrade-device-secure.png"
SECURE_DEVICE_PX="$(pixel_at "$TMP/degrade-device-secure.png" 400 150)"
SECURE_AGENT_PX="$(pixel_at "$TMP/degrade-agent-secure.png" 400 150)"
echo "secure pixel: agent=$SECURE_AGENT_PX device=$SECURE_DEVICE_PX"
[ "$SECURE_DEVICE_PX" = "0,0,0,255" ] \
  || { echo "FAIL: the device capture of a FLAG_SECURE window should be blank, got $SECURE_DEVICE_PX"; exit 1; }
[ "$SECURE_AGENT_PX" != "0,0,0,255" ] \
  || { echo "FAIL: the in-process capture should be unaffected by FLAG_SECURE, got $SECURE_AGENT_PX"; exit 1; }
R debug logs --package "$PKG" | grep -q "screenshot_secure_toggled" \
  || { echo "FAIL: expected screenshot_secure_toggled in the app log bridge"; exit 1; }

echo "== THIRD-PARTY WEBVIEW KERNEL (a boundary that says its own name) =="
# `WebViewBridge` is typed on android.webkit.WebView, so an X5/TBS or UC kernel has
# NO DOM at any level — and the failure used to be indistinguishable from a page
# that happened to be empty. A reflective adapter was rejected (unverifiable without
# a real kernel sample), so the deliverable is the label, not the capability.
# The fixture is a self-drawn view whose class is named WebView but is not the
# platform one — exactly the shape the shipped rule tests — next to a REAL WebView,
# because the contrast is what makes the marker mean anything.
open_scenario scenario.foreignKernel kernel.foreign
KERNEL_COMPACT="$(R ui compact --live --package "$PKG")"
echo "$KERNEL_COMPACT"
echo "$KERNEL_COMPACT" | grep "kernel.foreign" | grep -q "dom:unsupported-kernel" \
  || { echo "FAIL: a suspected third-party kernel must be marked dom:unsupported-kernel"; exit 1; }
# The real WebView beside it still has its DOM: the marker is about THIS kernel, not
# a blanket "web is unreadable".
echo "$KERNEL_COMPACT" | grep -q "Real WebView DOM" \
  || { echo "FAIL: the real WebView's DOM must still be captured on the same screen"; exit 1; }
echo "$KERNEL_COMPACT" | grep "kernel.real" | grep -q "dom:unsupported-kernel" \
  && { echo "FAIL: a real android.webkit.WebView must NOT be flagged as a foreign kernel"; exit 1; }
# The claim carries its evidence: which class triggered it.
R ui node --live --package "$PKG" --test-id kernel.foreign | grep -q "foreignkernel.WebView" \
  || { echo "FAIL: the node must name the class behind the kernel suspicion"; exit 1; }
# And the wall is explained where an agent actually hits it — a --css miss.
KERNEL_MISS="$(R act tap --package "$PKG" --css "#not-there" 2>&1 || true)"
echo "$KERNEL_MISS" | grep -q "third-party WebView kernel" \
  || { echo "FAIL: a --css miss must explain the kernel boundary, got: $KERNEL_MISS"; exit 1; }

echo "== INJECTION path (noagent app, JDWP) =="
# The noagent flavor carries none of dev.reticle.agent.* — the injected dex is
# their sole source. Prove observation works in an app that never linked the AAR.
"$ADB" -s "$SERIAL" shell am force-stop "$NOAGENT" >/dev/null 2>&1 || true
sleep 1
"$ADB" -s "$SERIAL" shell monkey -p "$NOAGENT" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
# Let the app fully come up before injecting — a debuggable app is only
# attachable over JDWP once its process is live and past the early dead-zone.
sleep 5
INJECT_OUT="$(R app inject --package "$NOAGENT" 2>&1 || true)"
echo "$INJECT_OUT"
# Inject's own await can lose the cold-start race on a slow emulator; the dex is
# loaded regardless, so confirm liveness by polling rather than trusting the
# single inject call.
wait_runtime "$NOAGENT"
wait_compact "$NOAGENT" "home.title"
R act tap --package "$NOAGENT" --test-id scenario.checkout >/dev/null
sleep 2
R ui report --package "$NOAGENT" --output "$TMP/inject"
R ui compact "$TMP/inject/snapshot.json" | grep -q "checkout.payButton" \
  || { echo "FAIL: injected runtime could not observe the checkout screen"; exit 1; }

echo "== OK: artifacts in $TMP =="
