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
# Poll until two consecutive live compacts are IDENTICAL, so a step that asserts
# "this action changed nothing" is not handed a tree that was still moving on its
# own. The measured case: an Activity started from the home list draws its own
# content (which is what `wait_compact` waits for) while the home Activity behind
# it is still RESUMED — its DecorView flips to `invisible` only when the stop
# finally lands, and on a loaded software-GPU emulator that can be seconds later.
# Caught inside one action's before/after span it reads as `2 change(s)` on a
# window the gesture never touched.
wait_quiet() { # package
  local pkg="$1" prev="" now="" deadline=$(( $(date +%s) + 30 ))
  prev="$(R ui compact --live --package "$pkg" 2>&1 || true)"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 2
    now="$(R ui compact --live --package "$pkg" 2>&1 || true)"
    if [ "$now" = "$prev" ]; then return 0; fi
    prev="$now"
  done
  # Not fatal: a genuinely animating screen never settles, and the assertion that
  # follows is the one entitled to judge that. Say so, so a later failure is read
  # as "the tree was still moving" rather than as the feature under test.
  echo "note: the tree was still changing after 30s; the next step's diff may carry it"
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
TRIGGER_TAP="$(R act tap --package "$PKG" --test-id popup.menuTrigger)"
# The confirm is the DEFAULT now, not just a `--settle` behaviour: an ordinary
# selector tap must report whether its point was confirmed at rest, because the
# same staleness comes from a relayout caused by an EARLIER command (a keyboard
# shown by `type`, a scroll) where no caller would think to pass a flag.
echo "$TRIGGER_TAP" | grep -q "settled=" \
  || { echo "FAIL: a plain selector tap must report settled=, got: $TRIGGER_TAP"; exit 1; }
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
# What the wheel PUBLISHES about itself. Measured on a real date picker, all of this
# used to be recovered from pixels: the values read off a screenshot, the row pitch
# measured in that same image, and a swipe distance calibrated by trial — four
# screenshot round-trips for "select 1995". Every one of these is public API on
# `android.widget.NumberPicker`.
echo "$WHEEL" | grep -qE '#wheel.hour container .* wheel:value="[0-9]+" [0-9]+/24 pitch=[0-9]+px~? items' \
  || { echo "FAIL: a NumberPicker must publish value, position and pitch, got: $WHEEL"; exit 1; }
# The labels themselves live on the node rather than on the compact line (a year
# wheel has 120 of them), and the whole set is there — not just the selection.
HOUR_FACTS="$(R ui node --live --package "$PKG" --test-id wheel.hour)"
echo "$HOUR_FACTS" | grep -A2 '"wheelItems"' | grep -q "00,01,02" \
  || { echo "FAIL: the wheel's item labels must be readable; got: $HOUR_FACTS"; exit 1; }
echo "$HOUR_FACTS" | grep -A2 '"wheelValue"' | grep -q '"09"' \
  || { echo "FAIL: the wheel must name its current value"; exit 1; }
# A pitch that was ESTIMATED (height/3, when the widget's own quantum is not
# reflectable) is marked as such — a swipe built on it can be off by a row, and
# passing an estimate off as a measurement is the failure this whole file guards.
echo "$HOUR_FACTS" | grep -q '"wheelRowHeightPx"' \
  || { echo "FAIL: the wheel must report a row pitch"; exit 1; }
# And the self-drawn column publishes NONE of it, which is the honest boundary: it
# stays `wheel:opaque` rather than being given invented numbers.
echo "$WHEEL" | grep -q '#wheel.year .* wheel:opaque' \
  || { echo "FAIL: a self-drawn wheel must still read opaque, got: $WHEEL"; exit 1; }
R ui node --live --package "$PKG" --test-id wheel.year | grep -q "wheelValue" \
  && { echo "FAIL: a self-drawn wheel must not carry invented wheel facts"; exit 1; }

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
# The marker: a wheel must not look like a decorative empty view. Two shapes, and
# the projection must not collapse them — a NumberPicker keeps its SELECTION as a
# node (its neighbours are pixels), while the self-drawn column publishes nothing
# at all, which is what a third-party date picker actually looks like.
WHEEL_MARKED="$(R ui compact --live --package "$PKG")"
echo "$WHEEL_MARKED" | grep '#wheel.year' | grep -q "wheel:opaque" \
  || { echo "FAIL: a self-drawn wheel must be marked wheel:opaque, got: $(echo "$WHEEL_MARKED" | grep '#wheel.year')"; exit 1; }
# A NumberPicker publishes its own state, so it carries the richer form rather than
# the bare `selection-only` fallback (which is what a wheel whose facts cannot be read
# still gets). The value here is whatever the drag above left it on, so the assertion
# is on the SHAPE, not on a number.
echo "$WHEEL_MARKED" | grep '#wheel.hour' | grep -qE 'wheel:value="[0-9]+" [0-9]+/24' \
  || { echo "FAIL: a NumberPicker must publish its value and range, got: $(echo "$WHEEL_MARKED" | grep '#wheel.hour')"; exit 1; }
# The NumberPicker's own value field must NOT be marked: it is the selection, not
# a column, and it is the one node here whose value IS readable. (Measured: a
# class-name match alone caught `NumberPicker$CustomEditText` and marked it
# `wheel:opaque` — the opposite of the truth, right under its parent's own marker.)
echo "$WHEEL_MARKED" | grep '#numberpicker_input' | grep -q "wheel:" \
  && { echo "FAIL: a wheel's value node must not be marked as a wheel column"; exit 1; }
# ...and an ordinary control on the same screen must NOT be marked: a false
# positive would send a caller swiping at a button.
echo "$WHEEL_MARKED" | grep '#wheel.confirm' | grep -q "wheel:" \
  && { echo "FAIL: a plain button must not carry a wheel marker"; exit 1; }
# The self-drawn column is drivable the way the marker says: swipe, then read the
# app's own committed state. There is no node for the value, by construction.
read -r YEAR_X YEAR_FROM_Y YEAR_TO_Y <<EOF
$(echo "$WHEEL_MARKED" | sed -nE 's/^#wheel\.year [a-zA-Z]+ .*\[([0-9]+),([0-9]+) ([0-9]+)x([0-9]+)\].*/\1 \2 \3 \4/p' \
   | awk '{ printf "%d %d %d\n", $1 + $3 / 2, $2 + $4 * 0.8, $2 + $4 * 0.2 }')
EOF
[ -n "${YEAR_TO_Y:-}" ] \
  || { echo "FAIL: could not read the self-drawn wheel's frame"; exit 1; }
R act swipe --package "$PKG" --from "$YEAR_X,$YEAR_FROM_Y" --to "$YEAR_X,$YEAR_TO_Y" --duration 300 >/dev/null
R act wait --package "$PKG" --idle >/dev/null

WHEEL_LOGS="$(R debug logs --package "$PKG")"
echo "$WHEEL_LOGS" | grep -q "wheel_year_changed" \
  || { echo "FAIL: the swipe never moved the self-drawn wheel (app-authored log is the only evidence there is)"; exit 1; }
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
# A row that IS in the tree but laid out past the bottom of the display is the
# other half of the same problem, and the one that used to be silent: the home
# scroller keeps its far-down rows bound, so the selector resolves, the tap
# dispatches at a y no display has, and the result reads `settled=1`. A tap that
# cannot land must say so, and name the command that fixes it.
OFF_ROW="$(/usr/bin/python3 - "$TMP/list/snapshot.json" <<'PY2'
import json, sys
snap = json.load(open(sys.argv[1]))
height = snap["screen"]["size"]["height"]
for node in snap["nodes"].values():
    frame, test = node.get("frame"), node.get("testId")
    if frame and test and frame["y"] >= height:
        print(test); break
PY2
)"
if [ -n "$OFF_ROW" ]; then
  OFF_TAP="$(R act tap --package "$PKG" --test-id "$OFF_ROW" 2>&1 || true)"
  echo "$OFF_TAP"
  echo "$OFF_TAP" | grep -q "laid out off screen" \
    || { echo "FAIL: a tap on a node laid out past the display must be refused: $OFF_TAP"; exit 1; }
  echo "$OFF_TAP" | grep -q "act scroll-to" \
    || { echo "FAIL: the off-screen refusal must name the command that fixes it"; exit 1; }
else
  echo "note: no node was laid out past the display on this device; off-screen refusal not exercised here"
fi

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

echo "== A CROSS-ORIGIN FRAME SAYS WHY IT IS EMPTY =="
# boundaries.md listed this as "not exercised (needs a second origin, and both
# suites run offline)". A `data:` URL gets an OPAQUE origin, so it is a genuinely
# cross-origin frame that needs no network — both twins now sit on one screen.
#
# The absence itself is the old boundary and is not the defect. The defect was that
# it was SILENT: an empty frame is byte-for-byte what one that has not finished
# loading looks like, so a caller retries, waits, and ends up measuring pixels off a
# screenshot. Measured on a real third-party widget: four consecutive steps done by
# coordinate because nothing in the tree said to stop trying.
boot_app "$PKG"
"$ADB" -s "$SERIAL" shell am start -n "$PKG/.WebViewScenarioActivity" \
  --es reticle.webScenario complex >/dev/null 2>&1
wait_compact "$PKG" "complex.iframeButton"
FRAMES="$(R ui compact --live --package "$PKG" --window top)"
echo "$FRAMES" | grep -q 'complex.foreignFrame .*iframe:cross-origin' \
  || { echo "FAIL: a cross-origin frame must say so, not just come back empty"; exit 1; }
# Its content stays absent — the marker explains the boundary, it does not lift it.
echo "$FRAMES" | grep -q "Inside foreign frame" \
  && { echo "FAIL: a cross-origin frame's content must not be readable"; exit 1; }
# And the same-origin twin beside it is still pierced and still unmarked.
echo "$FRAMES" | grep -q 'complex.iframeButton' \
  || { echo "FAIL: the same-origin frame must still be pierced"; exit 1; }
echo "$FRAMES" | grep -q 'complex.iframe .*iframe:cross-origin' \
  && { echo "FAIL: a same-origin frame must not be marked cross-origin"; exit 1; }

echo "== A SCREEN COVERED BY ANOTHER, INSIDE ONE WINDOW =="
# Occlusion was window-level only, which misses the shape a hybrid app really has:
# a second screen pushed over a still-alive one inside ONE window. Measured on this
# fixture before the fix — the covered page's button was projected as an ordinary
# `tappable` node, a tap on it reported `settled=1`, and nothing happened, because
# the touch went to the cover. That is the silent-wrong-answer shape.
open_scenario scenario.nestedWebViewsCovered nested.overlayButton
COVERED="$(R ui compact --live --package "$PKG" --window top)"
echo "$COVERED" | grep -q 'nested.backdropButton .*occluded-by:' \
  || { echo "FAIL: a control covered by a later sibling must say it is occluded"; exit 1; }
echo "$COVERED" | grep -q 'nested.overlayButton .*occluded-by:' \
  && { echo "FAIL: the covering page's own control must NOT read as occluded"; exit 1; }

# The false-positive guard for the same marker, one layer up: a full-screen
# container that draws NOTHING at a point does not occlude it. An in-app debug
# overlay is exactly that shape, and treating it as a cover marked every item on
# the screen occluded while every one of them was tappable. A web view is exempt —
# the native view eats the touch wherever it lies — which is why the covered page
# above still reports occlusion at every point.
echo "$COVERED" | grep -q 'nested.overlayWebView .*occluded-by:' \
  && { echo "FAIL: the top-most cover must not report itself occluded"; exit 1; }

# And the inset variant is the false-positive guard: there the backdrop's top
# controls are genuinely visible and must carry no marker, while the full-bleed
# container whose own tap point IS under the cover still does.
open_scenario scenario.nestedWebViews nested.overlayButton
INSET="$(R ui compact --live --package "$PKG" --window top)"
echo "$INSET" | grep -q 'nested.backdropButton .*occluded-by:' \
  && { echo "FAIL: a genuinely visible control must not be marked occluded"; exit 1; }
echo "$INSET" | grep -q 'nested.backdropWebView .*occluded-by:' \
  || { echo "FAIL: a container whose own tap point is covered must still say so"; exit 1; }
# The proof that the marker tracks reality: this tap works, and the covered one did not.
R act tap --package "$PKG" --test-id nested.backdropButton >/dev/null
wait_compact "$PKG" "Backdrop hit" \
  || { echo "FAIL: the unmarked control was not actually tappable"; exit 1; }

echo "== CLIPPED NODES AND THE TRAVERSAL'S OWN CAP =="
# Two things every other web fixture is blind to. Both are about a tree that looks
# complete and is not.
boot_app "$PKG"
"$ADB" -s "$SERIAL" shell am start -n "$PKG/.WebViewScenarioActivity" \
  --es reticle.webScenario clipped >/dev/null 2>&1
wait_compact "$PKG" "Clipped fixture"
CLIPPED_COMPACT="$(R ui compact --live --package "$PKG" --window top)"

# 1. An `overflow: hidden` roller whose items are laid out well outside it.
# `getComputedStyle` reports them as perfectly ordinary — display and visibility
# untouched — and their rects land inside the WINDOW viewport, so nothing told them
# apart from what is on screen. Measured on a real page, a 10-item counter strip put
# nine unseeable digits into the tree, where they padded every projection and were
# cited as `--label` ambiguities.
CLIPPED_DIGITS="$(echo "$CLIPPED_COMPACT" | grep -c 'li "' || true)"
[ "$CLIPPED_DIGITS" -le 4 ] \
  || { echo "FAIL: clipped roller items must not be projected as visible (got $CLIPPED_DIGITS)"; exit 1; }
# The one the user CAN see is untouched — the check must not have eaten the row.
echo "$CLIPPED_COMPACT" | grep -q 'clipped.visibleFive' \
  || { echo "FAIL: the visible control was dropped by the clipping check"; exit 1; }
# A scrollable clip behaves the same way: the row below the fold is not visible now.
echo "$CLIPPED_COMPACT" | grep -q 'scroll-row-4' \
  && { echo "FAIL: a row scrolled out of an overflow container must not read as visible"; exit 1; }
echo "$CLIPPED_COMPACT" | grep -q 'scroll-row-1' \
  || { echo "FAIL: the rows inside the scroll port must stay visible"; exit 1; }

# 2. The traversal's own node cap, said out loud. The projection's cap already
# announces itself; this one stopped silently, so a partial DOM read as the whole
# page — and unlike the projection's, nothing downstream can recover nodes that
# were never captured.
echo "$CLIPPED_COMPACT" | grep -qE 'webView .*dom:capped\([0-9]+\)' \
  || { echo "FAIL: a DOM walk that hit its cap must say so on the host node"; exit 1; }

# 3. `ui outline` numbers what is ON SCREEN, not the whole scrollable tree. Measured
# on a real home screen: 135 aliases whose last entry sat at y=10800 on a 2412-tall
# device, about 15 of them actually visible.
boot_app "$PKG"
R ui outline --live --package "$PKG" > "$TMP/outline.txt"
/usr/bin/python3 - "$TMP/outline.txt" <<'OUTLINE_PY' || exit 1
import re, sys
# Judged against the screen height the outline itself reports, not a literal. The
# rule is "on screen", and `onScreen` is an INTERSECTION test — so a row whose top
# is on screen and whose bottom is past it is partially visible and must be kept.
# A hardcoded 2000 read that as a failure on a 2400-tall emulator, where the home
# list's tenth row starts at y=2204: the assertion was stricter than the rule.
height = None
ys = []
for line in open(sys.argv[1]):
    if line.startswith("Screen:"):
        m = re.search(r"(\d+)x(\d+)", line)
        if m:
            height = int(m.group(2))
        continue
    if not line.startswith("@"):
        continue
    m = re.search(r"\[(-?\d+),(-?\d+) (\d+)x(\d+)\]", line)
    if m:
        ys.append(int(m.group(2)))
if height is None:
    print("FAIL: outline did not report the screen size, so 'on screen' cannot be judged")
    sys.exit(1)
beyond = [y for y in ys if y >= height]
if beyond:
    print(f"FAIL: outline numbered {len(beyond)} alias(es) starting below the {height}px screen: {beyond[:5]}")
    sys.exit(1)
OUTLINE_PY

echo "== CSS SELECTORS ARE MATCHED, NOT STRING-COMPARED =="
# `--css` used to be a string comparison against each node's captured
# `domCssSelector` — the full ancestor path — so only a verbatim copy of that path
# could ever match. Every short form the docs promise (`--css '#pay'`,
# `--css 'input.some-class'`) silently missed on a real page, and the miss then
# printed twelve complete ancestor chains of unrelated nodes as "candidates".
boot_app "$PKG"
"$ADB" -s "$SERIAL" shell am start -n "$PKG/.WebViewScenarioActivity" \
  --es reticle.webScenario form >/dev/null 2>&1
wait_compact "$PKG" "First name"

# A class-only selector, on a page whose inputs carry no id at all.
R ui node --live --package "$PKG" --css '.fake-select' >/dev/null \
  || { echo "FAIL: a class-only css selector must resolve structurally"; exit 1; }
# A descendant combinator, walking the captured parent chain.
R ui node --live --package "$PKG" --css 'div.row input' >/dev/null \
  || { echo "FAIL: a descendant css combinator must resolve"; exit 1; }
# And it drives input, not just lookup.
R act tap --package "$PKG" --css 'div.fake-select' >/dev/null \
  || { echo "FAIL: act must accept a structural css selector"; exit 1; }
sleep 1
R ui compact --live --package "$PKG" --window top | grep -q 'combobox .*expanded' \
  || { echo "FAIL: the css-resolved tap did not land on the trigger"; exit 1; }

# `:nth-of-type(n)` — the one pseudo-class family the captured paths are BUILT out
# of, and until now the matcher refused it. That made the only selector the tool
# emits one it accepted solely as a verbatim whole string: trimming the path or
# aiming at the next sibling was rejected, so driving this form by CSS meant pasting
# a ~400-char path per interaction. The index is the position the PAGE reported, not
# a count of captured siblings — the walk drops hidden elements, so counting would
# answer `(2)` with the second VISIBLE sibling and tap the wrong control.
NTH_FIRST="$(R ui node --live --package "$PKG" --css 'div:nth-of-type(1) input' 2>&1)"
echo "$NTH_FIRST" | grep -A2 '"domPlaceholder"' | grep -q "First name" \
  || { echo "FAIL: :nth-of-type(1) must resolve the first row's input; got: $NTH_FIRST"; exit 1; }
NTH_SECOND="$(R ui node --live --package "$PKG" --css 'div:nth-of-type(2) input' 2>&1)"
echo "$NTH_SECOND" | grep -A2 '"domPlaceholder"' | grep -q "Last name" \
  || { echo "FAIL: the index must actually select — (2) is the second row; got: $NTH_SECOND"; exit 1; }
# The position is the PAGE's, carried per node, not a count of captured siblings.
echo "$NTH_SECOND" | grep -q '"domNthOfType"' \
  || { echo "FAIL: a captured DOM node must carry its page sibling position"; exit 1; }
# And it drives input, not just lookup: this is the loop the flow needed.
R act type --package "$PKG" --css 'div:nth-of-type(2) input' --text "Nth" >/dev/null
R ui compact --live --package "$PKG" | grep -q '"Nth" .*placeholder:"Last name"' \
  || { echo "FAIL: an nth-of-type selector must drive `act`, not only `ui node`"; exit 1; }
# A pseudo-class that is NOT positional is still refused, by its own name.
HOVER="$(R ui node --live --package "$PKG" --css 'input:hover' 2>&1 || true)"
echo "$HOVER" | grep -q "':hover'" \
  || { echo "FAIL: an unsupported pseudo-class must be refused by name; got: $HOVER"; exit 1; }
# So is an an+b expression — refused as itself rather than as "a sibling combinator",
# which is what a bare character scan would have called the `+`.
ANB="$(R ui node --live --package "$PKG" --css 'input:nth-of-type(2n+1)' 2>&1 || true)"
echo "$ANB" | grep -q "plain 1-based index" \
  || { echo "FAIL: an an+b nth expression must be refused as itself; got: $ANB"; exit 1; }
# A dead REF on this screen: refs are traversal indices, and a DOM re-render
# renumbers the tree, so one read out of an earlier report is frequently gone ~1s
# later. Measured on a hybrid screen, the answer was twelve NATIVE refs — none of
# which can stand in for a DOM node — plus a recycling-list note while nothing had
# scrolled. Now it says what a ref is and offers handles that survive a re-render.
REF_MISS="$(R act tap --package "$PKG" --ref r9999 2>&1 || true)"
echo "$REF_MISS" | grep -q "traversal INDEX" \
  || { echo "FAIL: a ref miss must say a ref is snapshot-scoped; got: $REF_MISS"; exit 1; }
echo "$REF_MISS" | grep -q -- "--css" \
  || { echo "FAIL: a ref miss on a DOM screen must name the handle that survives"; exit 1; }
echo "$REF_MISS" | grep -q "recycling list" \
  && { echo "FAIL: a ref miss on a DOM screen must not blame scrolling"; exit 1; }
# And the offered handle is one that actually resolves — a bare 'input' would match
# the first of forty, trading one wrong node for another.
REF_HANDLE="$(echo "$REF_MISS" | sed -n "s/.*by hand): '\([^']*\)'.*/\1/p")"
[ -n "$REF_HANDLE" ] || { echo "FAIL: no css handle was offered; got: $REF_MISS"; exit 1; }
R ui node --live --package "$PKG" --css "$REF_HANDLE" >/dev/null \
  || { echo "FAIL: the offered handle '$REF_HANDLE' does not resolve"; exit 1; }

# A construct the matcher does not implement is REFUSED by name, never answered as
# a miss: "not understood" and "no such element" lead to opposite next actions.
UNSUPPORTED="$(R ui node --live --package "$PKG" --css 'input[type=checkbox]' 2>&1 || true)"
echo "$UNSUPPORTED" | grep -q "attribute selectors" \
  || { echo "FAIL: an unsupported css construct must be refused by name, got: $UNSUPPORTED"; exit 1; }

# A miss offers only candidates that share something with the query, by their
# shortest handle — not every captured path on the page.
MISS="$(R ui node --live --package "$PKG" --css '.no-such-class' 2>&1 || true)"
echo "$MISS" | grep -q "nth-of-type" \
  && { echo "FAIL: a css miss must not dump full captured ancestor paths"; exit 1; }

echo "== DOM GEOMETRY UNDER ZOOM AND STACKING (coordinate taps, not activation) =="
# Every other web fixture renders 1:1 in a single full-bleed WebView — the one
# arrangement where a wrong page-to-device fold and a right one agree. These two
# don't, and both assert with a COORDINATE tap: DOM activation would fire the
# handler even if the reported geometry were nonsense, so it proves nothing here.
#
# 1. Zoom. A zoomed WebView keeps its LAYOUT viewport (`window.innerWidth`) and
# scales only what it paints, so a fold derived from innerWidth alone looks like it
# must be off by the zoom factor. It is not — this pins that it stays right.
boot_app "$PKG"
"$ADB" -s "$SERIAL" shell am start -n "$PKG/.WebViewScenarioActivity" \
  --es reticle.webScenario scaled >/dev/null 2>&1
wait_compact "$PKG" "scaled.target"
R act tap --package "$PKG" --test-id scaled.target >/dev/null
wait_compact "$PKG" "Scaled target hit" \
  || { echo "FAIL: a coordinate tap under zoom did not land on the element"; exit 1; }

# 1b. A page that has been SCROLLED. Every other web fixture fits its viewport, so
# the page scroll was always 0 and a fold that mishandled it could not fail here —
# which is how a scroll-coupled fold error survived: the traversal emitted PAGE
# coordinates (rect + window.scrollY, read per element DURING the walk) and the host
# subtracted the scroll (read once, AFTER it), two reads from different moments.
# Measured on a real page as roughly 130px of offset, silent (`settled=1`, nothing
# happened). Rects are viewport-space now, so no scroll enters the fold at all.
boot_app "$PKG"
"$ADB" -s "$SERIAL" shell am start -n "$PKG/.WebViewScenarioActivity"   --es reticle.webScenario scrolled >/dev/null 2>&1
wait_compact "$PKG" "scrolled.status"
# Below the fold to begin with: the target is genuinely not on screen, and the
# projection says so by leaving it out rather than reporting an off-screen rect.
R ui compact --live --package "$PKG" | grep -q "scrolled.target"   && { echo "FAIL: a target below the fold must not be projected as if on screen"; exit 1; }
# Scroll to the bottom of the document (the target is the last element, so this needs
# no calibrated swipe count — the page simply stops).
for _ in 1 2 3 4 5 6; do
  R act swipe --package "$PKG" --from 540,2000 --to 540,400 --duration 250 >/dev/null
done
wait_compact "$PKG" "scrolled.target"   || { echo "FAIL: the target never came into view after scrolling to the bottom"; exit 1; }
# The verdict: a COORDINATE tap at the projected rect, which only fires the page's
# own onclick if that rect agrees with what is rendered. The status is `position:
# fixed`, so it is readable at any scroll offset.
R act tap --package "$PKG" --test-id scrolled.target >/dev/null
wait_compact "$PKG" "Scrolled target hit"   || { echo "FAIL: a coordinate tap on a scrolled page did not land on the element"; exit 1; }
# And the in-page scroll port beside it is reported as one — the second half of the
# shape measured on the real page (its container read `scroll:down,right`).
R ui compact --live --package "$PKG" | grep -q "scrolled.strip"   || { echo "FAIL: the in-page scroll strip must still be captured"; exit 1; }

# 2. Two live WebViews in one window, the second inset on BOTH axes and its target
# deep into its own page — so the rect is only right if the overlay's own container
# offset and the page offset are both accumulated. A rect computed against the
# backdrop's origin is plausible, and lands on the backdrop.
open_scenario scenario.nestedWebViews nested.overlayButton
R act tap --package "$PKG" --test-id nested.overlayButton >/dev/null
wait_compact "$PKG" "Overlay hit" \
  || { echo "FAIL: a coordinate tap in a stacked WebView did not land on the overlay"; exit 1; }
# And the backdrop underneath was NOT the thing that got hit.
R ui compact --live --package "$PKG" | grep -q "Backdrop hit" \
  && { echo "FAIL: the tap fell through to the backdrop WebView"; exit 1; }

echo "== A MISPLACED FLAG IS REPORTED AS ONE, AND A MISS NAMES --label =="
# Measured while driving a real flow: `act tap --text "Tak"` answered "could not
# resolve selector '<empty>'", which reads as an empty selector rather than a flag
# `act tap` does not take — and `--text` IS valid on `act type` / `act wait`, so
# "unknown" was never obvious. Both halves of the answer are asserted.
MISPLACED="$(R act tap --package "$PKG" --text "Tak" 2>&1 || true)"
echo "$MISPLACED" | grep -q "unknown option --text for \`act tap\`" \
  || { echo "FAIL: a flag this gesture does not read must be reported by name; got: $MISPLACED"; exit 1; }
echo "$MISPLACED" | grep -q "accepted by: act type, act wait" \
  || { echo "FAIL: the message must name where the flag DOES belong; got: $MISPLACED"; exit 1; }
# A plain typo has no home to point at, and the accepted list carries the fix.
TYPO="$(R ui compact --live --package "$PKG" --windwo top 2>&1 || true)"
echo "$TYPO" | grep -q -- "unknown option --windwo" \
  || { echo "FAIL: a typo'd flag must be reported; got: $TYPO"; exit 1; }
echo "$TYPO" | grep -q -- "--window" \
  || { echo "FAIL: the accepted list must contain the flag that was meant"; exit 1; }
# The guard against the fix being worse than the gap: everything a gesture really
# reads is still accepted (these fail on the SELECTOR, not on a flag).
R act type --package "$PKG" --test-id no.such.field --text abc --clear --submit \
  --type-delay 40 2>&1 | grep -q "unknown option" \
  && { echo "FAIL: a flag act type really reads was rejected"; exit 1; }
# And a selector-less act names the flag that resolves a visible string. That
# omission is how the same flow got driven by coordinates on screens whose only
# stable handle was the on-screen text.
NO_SELECTOR="$(R act tap --package "$PKG" 2>&1 || true)"
echo "$NO_SELECTOR" | grep -q -- '--label "<visible text>"' \
  || { echo "FAIL: a selector miss must name --label; got: $NO_SELECTOR"; exit 1; }

echo "== COVERAGE: THE SCREEN REPORTS WHAT AN AGENT CANNOT ADDRESS =="
# `--point` was the silent fallback. Measured over one hybrid-app onboarding flow:
# 23 of ~50 taps were coordinates, 13 screenshots had to be read with human eyes to
# make progress, and NOTHING in any of those results said so — the only way to find
# the gaps that forced them was to drive the flow by hand and count. Two things
# close that: every coordinate tap now carries a verdict, and the screen can be
# asked the question directly.
boot_app "$PKG"
"$ADB" -s "$SERIAL" shell am start -n "$PKG/.WebViewScenarioActivity" \
  --es reticle.webScenario complex >/dev/null 2>&1
wait_compact "$PKG" "complex.iframeButton"

COVERAGE="$(R ui coverage --live --package "$PKG")"
# The sampling is a STATED fact, not a hidden approximation.
echo "$COVERAGE" | grep -qE '^coverage: [0-9]+x[0-9]+, sampled on a [0-9]+x[0-9]+ grid of [0-9]+px cells$' \
  || { echo "FAIL: coverage must state the grid it sampled; got: $(echo "$COVERAGE" | head -1)"; exit 1; }
echo "$COVERAGE" | grep -qE '^addressable: [0-9]+ of [0-9]+ touch-relevant cell\(s\) \([0-9]+%\)$' \
  || { echo "FAIL: coverage must report the addressable share"; exit 1; }
# This screen HAS a named unreachable region — the cross-origin frame — and it is
# listed with the host ref and rect an agent would act on.
echo "$COVERAGE" | grep -qE '^  iframe:cross-origin r[0-9]+ \[[0-9]+,[0-9]+ [0-9]+x[0-9]+\] [0-9]+ cell\(s\)$' \
  || { echo "FAIL: the cross-origin frame must appear as a named coverage gap"; echo "$COVERAGE"; exit 1; }
# And the number is not the constant it was before a screen-sized tappable WebView
# stopped counting as cover for everything inside it (that read as 100%).
COVERAGE_PCT="$(echo "$COVERAGE" | sed -n 's/^addressable:.*(\([0-9]*\)%)$/\1/p')"
[ -n "$COVERAGE_PCT" ] && [ "$COVERAGE_PCT" -lt 100 ] \
  || { echo "FAIL: a screen with an unreadable frame on it cannot be 100% addressable (got ${COVERAGE_PCT:-none}%)"; exit 1; }

# A screen-sized container over the point is not cover — and not a gap either. It
# gets its own line and stays OUT of the addressable ratio: measured on a screen
# carrying a full-screen debug overlay, folding those cells into the gap total read
# as 31% addressable while every control on the screen resolved and every tap
# landed. A boundary the container declares (the cross-origin frame above) is still
# a gap, which is what keeps the number meaningful.
if echo "$COVERAGE" | grep -q "^container-only:"; then
  echo "$COVERAGE" | grep -qE "^  container-only .* cell\(s\)$" \
    && { echo "FAIL: container-only cells must not also be listed as an unreachable gap"; exit 1; }
  echo "$COVERAGE" | grep -q "NOT counted as gaps" \
    || { echo "FAIL: the footnote must say which buckets are not gaps"; exit 1; }
fi

# `--package` alone means the live tree. It used to be rejected in favour of
# `--live --package`, which cost one failed command at the start of every session
# for no information — a package name cannot be mistaken for a snapshot path, and
# every other command already takes `--package` on its own.
R ui coverage --package "$PKG" | grep -q "^coverage: " \
  || { echo "FAIL: ui coverage --package alone must read the live tree"; exit 1; }
R ui compact --package "$PKG" | grep -q "complex.iframeButton" \
  || { echo "FAIL: ui compact --package alone must read the live tree"; exit 1; }
# With neither a path nor a package there is still nothing to read, and the message
# now names the form that works.
NO_TARGET="$(R ui compact 2>&1 || true)"
echo "$NO_TARGET" | grep -q -- "--package <pkg> for the live tree" \
  || { echo "FAIL: with no target, the error must name --package; got: $NO_TARGET"; exit 1; }
# An explicit path still wins over --package, so scripts that pass both keep reading
# the file they named.
R ui compact --package "$PKG" "$TMP/webview/snapshot.json" | grep -q "web.payButton" \
  || { echo "FAIL: an explicit snapshot path must win over --package"; exit 1; }

# A coordinate INSIDE the cross-origin frame: the fallback is justified, and the
# warning names the boundary rather than leaving the coordinate unexplained.
FRAME_POINT="$(R ui compact --live --package "$PKG" | /usr/bin/python3 -c '
import re, sys
for line in sys.stdin:
    if "complex.foreignFrame" not in line:
        continue
    m = re.search(r"\[(-?\d+),(-?\d+) (\d+)x(\d+)\]", line)
    if m:
        x, y, w, h = (int(g) for g in m.groups())
        print(f"{x + w // 2},{y + h // 2}")
        break
')"
[ -n "$FRAME_POINT" ] || { echo "FAIL: could not read the cross-origin frame rect"; exit 1; }
FRAME_TAP="$(R act tap --package "$PKG" --point "$FRAME_POINT" --no-toast-probe 2>&1)"
echo "$FRAME_TAP" | grep -q "warning: no semantic selector covers" \
  || { echo "FAIL: a coordinate with no selector over it must say so; got: $FRAME_TAP"; exit 1; }
echo "$FRAME_TAP" | grep -q "iframe:cross-origin" \
  || { echo "FAIL: the warning must name the boundary that justified the coordinate"; exit 1; }

# A coordinate over a control that HAD a selector: the opposite report. This is the
# quieter loss — the agent measured pixels for something it could have named, giving
# up the re-resolution and the settle confirm a selector tap performs.
BUTTON_POINT="$(R ui compact --live --package "$PKG" | /usr/bin/python3 -c '
import re, sys
for line in sys.stdin:
    if "complex.iframeButton" not in line:
        continue
    m = re.search(r"\[(-?\d+),(-?\d+) (\d+)x(\d+)\]", line)
    if m:
        x, y, w, h = (int(g) for g in m.groups())
        print(f"{x + w // 2},{y + h // 2}")
        break
')"
[ -n "$BUTTON_POINT" ] || { echo "FAIL: could not read the frame button rect"; exit 1; }
BUTTON_TAP="$(R act tap --package "$PKG" --point "$BUTTON_POINT" --no-toast-probe 2>&1)"
echo "$BUTTON_TAP" | grep -q "warning: --point was not needed" \
  || { echo "FAIL: a coordinate over an addressable node must be reported as unnecessary; got: $BUTTON_TAP"; exit 1; }
echo "$BUTTON_TAP" | grep -q "complex.iframeButton" \
  || { echo "FAIL: the warning must name the flag that would have worked"; exit 1; }

# A healthy page carries no rect complaint. The positive case — a DOM rect folded
# to a point OUTSIDE the web view that draws it — cannot be staged in a fixture (it
# takes a wrong fold, not a wrong page), so it is pinned by unit tests on both ports;
# what a device run adds is the guard that the check stays quiet when the fold is
# right. A warning that fires on ordinary screens is one nobody reads.
R act tap --package "$PKG" --test-id complex.iframeButton --no-toast-probe 2>&1   | grep -q "folded to a point OUTSIDE"   && { echo "FAIL: a correctly folded DOM rect must not be reported as suspect"; exit 1; }

# And a selector tap carries no verdict at all: it resolved through the tree, so a
# warning on every action would be noise an agent learns to ignore.
R act tap --package "$PKG" --test-id complex.iframeButton --no-toast-probe 2>&1 \
  | grep -q "^warning:" \
  && { echo "FAIL: a selector tap must not print a coverage warning"; exit 1; }

echo "== WEB FORM SEMANTICS (role by type, placeholder, checked, invalid) =="
# The shape the complex fixture is the opposite of: a form built out of framework
# components, where no input carries an id, a data-testid or a value. What used to
# come back was several identical `textField` lines separable only by y-coordinate,
# every input type flattened to `textField`, and no toggle state anywhere — so the
# only way to read a consent box was a screenshot.
boot_app "$PKG"
"$ADB" -s "$SERIAL" shell am start -n "$PKG/.WebViewScenarioActivity" \
  --es reticle.webScenario form >/dev/null 2>&1
wait_compact "$PKG" "First name"
FORM_COMPACT="$(R ui compact --live --package "$PKG")"
echo "$FORM_COMPACT"

# 1. An input's TYPE is its role. `domInputType` was already captured and then
# discarded by the mapping, which turned a consent checkbox into a text field.
echo "$FORM_COMPACT" | grep -q 'checkbox .*Accept the terms' \
  || { echo "FAIL: input[type=checkbox] must project as role checkbox"; exit 1; }
echo "$FORM_COMPACT" | grep -q 'radio .*Plan A' \
  || { echo "FAIL: input[type=radio] must project as role radio"; exit 1; }
echo "$FORM_COMPACT" | grep -q 'slider .*Volume' \
  || { echo "FAIL: input[type=range] must project as role slider"; exit 1; }
echo "$FORM_COMPACT" | grep -Eq 'button .*(Confirm|submit-form)' \
  || { echo "FAIL: input[type=submit] must project as role button, not textField"; exit 1; }

# 2. Toggle state is readable, and its THIRD state is the absent one. `unchecked`
# and "no checkbox here" lead to opposite next actions.
echo "$FORM_COMPACT" | grep -q 'Accept the terms.* unchecked' \
  || { echo "FAIL: an unticked checkbox must render ' unchecked'"; exit 1; }
echo "$FORM_COMPACT" | grep -q 'Plan A.* checked' \
  || { echo "FAIL: a checked radio must render ' checked'"; exit 1; }
echo "$FORM_COMPACT" | grep -q 'Select all consents.* checked:mixed' \
  || { echo "FAIL: aria-checked=mixed must render ' checked:mixed'"; exit 1; }
# The value-shadows-label case, asserted directly rather than only through the tap
# above: this radio's `value` is "b" and its only human-readable name is its label.
R act tap --package "$PKG" --label "Plan B" >/dev/null \
  || { echo "FAIL: --label must reach a control whose value shadows its aria-label"; exit 1; }
sleep 1
R ui compact --live --package "$PKG" | grep -q 'Plan B.* checked' \
  || { echo "FAIL: the radio --label selected did not become checked"; exit 1; }
# The state must FOLLOW the app, not be captured once: tick it and read it back.
# This tap is also the assertion for `--label` reaching an aria-labelled control:
# these carry no id and no visible text, so `--label` is the only selector the
# skill documents for them — and it used to match `text ?? contentDescription`,
# a fallback, so the input's `value` shadowed its label and none of them resolved.
R act tap --package "$PKG" --label "Accept the terms" >/dev/null
R ui compact --live --package "$PKG" | grep -q 'Accept the terms.* checked' \
  || { echo "FAIL: checked state must track the live control after a tap"; exit 1; }

# 3. Placeholder is its own field, never folded into the value. Folding them made
# an empty field and a filled one project identically — which is also why
# `act type`'s read-back could not tell whether text had landed.
echo "$FORM_COMPACT" | grep -q 'placeholder:"First name"' \
  || { echo "FAIL: an empty input must carry its placeholder as placeholder:, not as its text"; exit 1; }
echo "$FORM_COMPACT" | grep -q '"First name"' && \
  echo "$FORM_COMPACT" | grep -Eq 'textField "First name"' \
  && { echo "FAIL: a placeholder must not be projected as the field's VALUE"; exit 1; }

# 4. The accessible name resolved through aria-labelledby, the way a screen reader
# resolves it — a separate element, not an attribute on the input.
echo "$FORM_COMPACT" | grep -q '"Document number"' \
  || { echo "FAIL: aria-labelledby must resolve to the referenced element's text"; exit 1; }

# 5. An invalid field says so AND carries its own message. Without the pairing the
# error text is an ordinary sibling node belonging to nothing.
echo "$FORM_COMPACT" | grep -q 'invalid:"Enter a valid postcode"' \
  || { echo "FAIL: aria-invalid + aria-describedby must render as invalid:\"<message>\""; exit 1; }

# 6. A DISABLED input is CAPTURED rather than absent. It used to fail every clause
# of `hasTargetingSignal` at once — not interactive, no id, no label, no value — so
# a form's not-yet-unlocked fields were missing from the projection entirely, which
# reads as "the app has no such field" rather than "not ready yet". The placeholder
# is both the signal that it IS a field and the only thing that says which one.
echo "$FORM_COMPACT" | grep -q 'disabled placeholder:"City"' \
  || { echo "FAIL: a disabled input must be captured and marked disabled, not omitted"; exit 1; }

# 6b. A dropdown built out of divs, driven end to end with no coordinates. Before
# this the trigger was in the tree as a plain node with nothing marked tappable, so
# the agent had a label and no executable next step — the single largest source of
# coordinate taps measured on a real form. A click handler bound in JS is not
# readable from the page, so the signals used are the ones the page DOES publish:
# `aria-haspopup` / `aria-expanded` / a widget `role`, and — where nothing else is
# declared — `cursor: pointer` at the node where it STARTS.
echo "$FORM_COMPACT" | grep -q 'combobox .*tappable collapsed popup:listbox' \
  || { echo "FAIL: an unopened div-built dropdown must be tappable and say it is shut"; exit 1; }
# `cursor` is inherited, so a pointer on a wrapper computes as pointer on every
# descendant. Marking all of them would turn one control into four.
echo "$FORM_COMPACT" | grep -q '#pointer-root .*tappable' \
  || { echo "FAIL: the node where a pointer cursor starts must be tappable"; exit 1; }
echo "$FORM_COMPACT" | grep -q '#pointer-leaf .*tappable' \
  && { echo "FAIL: an inherited pointer cursor must not make every descendant tappable"; exit 1; }
# Open it. A caption and the control it names share one string here (the control
# takes its name from the caption via aria-labelledby); resolving that to the
# ACTIONABLE one is what keeps `--label` usable for the control it exists to reach.
R act tap --package "$PKG" --label "Education" >/dev/null \
  || { echo "FAIL: --label must resolve a caption/control pair to the control"; exit 1; }
sleep 1
OPENED="$(R ui compact --live --package "$PKG" --window top)"
echo "$OPENED" | grep -q 'combobox .*expanded' \
  || { echo "FAIL: the trigger must report itself expanded after the tap"; exit 1; }
echo "$OPENED" | grep -q 'option "University" .*tappable' \
  || { echo "FAIL: the options must materialise as tappable nodes once opened"; exit 1; }
# Pick one, and take the app's own committed state as the verdict.
R act tap --package "$PKG" --label "University" >/dev/null
sleep 1
PICKED="$(R ui compact --live --package "$PKG" --window top)"
echo "$PICKED" | grep -q 'combobox .*collapsed' \
  || { echo "FAIL: the dropdown did not close after a selection"; exit 1; }
echo "$PICKED" | grep -q '"University"' \
  || { echo "FAIL: the selected value did not reach the trigger"; exit 1; }

# 7. The whole form driven with NO coordinates, and every step verified from the
# field's own text. Three things had to be true at once for this to work, and each
# was separately broken:
#   - `--label` taps the field first (it was missing from `type`'s selector list,
#     so the text went to whatever already held focus and still reported success);
#   - `--label` matches a placeholder (an empty input on such a form has no id, no
#     value and no accessible name — the grey prompt is the whole handle);
#   - the read-back applies to DOM inputs at all (it was refused for every one of
#     them while `value` and `placeholder` were captured as one string).
R act type --package "$PKG" --label "First name" --text "Ada" | tee "$TMP/type-first.txt"
grep -q "textLanded=exact" "$TMP/type-first.txt" \
  || { echo "FAIL: a DOM input must be read back, not reported unreadable"; exit 1; }
grep -q "text=Ada" "$TMP/type-first.txt" \
  || { echo "FAIL: the read-back must report the field's own text"; exit 1; }
grep -q "focusedVia=label" "$TMP/type-first.txt" \
  || { echo "FAIL: type must TAP a --label target before dispatching"; exit 1; }
R act type --package "$PKG" --label "Email" --text "ada@example.com" >/dev/null
R act type --package "$PKG" --label "Postcode" --text "00-001" >/dev/null
FILLED="$(R ui compact --live --package "$PKG")"
echo "$FILLED" | grep -q '"Ada" .*placeholder:"First name"' \
  || { echo "FAIL: the value and the placeholder must both be readable, side by side"; exit 1; }
echo "$FILLED" | grep -q '"ada@example.com"' \
  || { echo "FAIL: the email did not land in the email field"; exit 1; }
# The page's own focus is captured now (`document.activeElement`), so the DOM half
# of the tree has a focus channel at all: before this, the platform focus sat on the
# host WebView and `type` could only ever report `focusLanded=ancestor`.
echo "$FILLED" | grep -qE 'textField .*focused' \
  || { echo "FAIL: the focused DOM input must be marked focused"; echo "$FILLED"; exit 1; }
# And a selector that resolves the WRAPPER rather than the input reads back the
# input inside it. Measured on a real form, that case answered
# `textLanded=unreadable textReadback=unavailable:dom-node-is-not-a-text-input`
# while a screenshot showed the value sitting in the field.
WRAPPED="$(R act type --package "$PKG" --css 'div.row.wrapped' --text "Wrap")"
echo "$WRAPPED"
echo "$WRAPPED" | grep -q "textLanded=exact" \
  || { echo "FAIL: typing at a DOM wrapper must read back the input inside it; got: $WRAPPED"; exit 1; }
echo "$WRAPPED" | grep -qE "text=.*Wrap" \
  || { echo "FAIL: the read-back must report the input's own text; got: $WRAPPED"; exit 1; }
echo "$WRAPPED" | grep -q "dom-node-is-not-a-text-input" \
  && { echo "FAIL: the wrapper case must no longer read as unreadable; got: $WRAPPED"; exit 1; }

# 8. The disabled field flips once the app unlocks it — the other half of 6, now
# that a DOM field can actually be typed into.
echo "$FILLED" | grep -q 'placeholder:"City"' \
  || { echo "FAIL: the city field vanished after being enabled"; exit 1; }
echo "$FILLED" | grep -q 'disabled placeholder:"City"' \
  && { echo "FAIL: the city field must stop reading disabled once the app enables it"; exit 1; }

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

echo "== TOASTS: an action answered out of tree is not an action that missed =="
# The measured blind spot. On Android 11+ a text toast is drawn by the SYSTEM in
# a window of its own, so it is in no snapshot of this app and in no in-process
# screenshot: the before/after pair is byte-identical and the step reads
# `0 change(s)` — the documented signal for a gesture that hit nothing. Every act
# now watches the system Toast Queue, which is the one channel that holds it.
open_scenario scenario.toasts toast.text
# This is the one section whose subject is an EMPTY diff, so it is the one that
# cannot start while the launch transition is still finishing behind it.
wait_quiet "$PKG"
TOAST_TRACES="$TMP/toast-traces"
# 1. Text toast: no tree change at all, and the message is still recovered.
TEXT_TOAST="$(R act tap --package "$PKG" --test-id toast.text --trace-output "$TOAST_TRACES")"
echo "$TEXT_TOAST"
echo "$TEXT_TOAST" | grep -q "toast=Amount exceeds your daily limit" \
  || { echo "FAIL: a text toast must be recovered from the Toast Queue, got: $TEXT_TOAST"; exit 1; }
echo "$TEXT_TOAST" | grep -q "toastKind=text" \
  || { echo "FAIL: the toast kind decides where its text lives, got: $TEXT_TOAST"; exit 1; }
# The point of the whole thing: this action really did change nothing in the tree.
echo "$TEXT_TOAST" | grep -q "0 change(s)" \
  || { echo "FAIL: expected a tree-silent action — the scenario is wrong, got: $TEXT_TOAST"; exit 1; }
sleep 4
# 2. Custom-view toast: the app drew it, so the TREE has the text and the queue
# record does not. Reticle must say which, not paper over the difference.
CUSTOM_TOAST="$(R act tap --package "$PKG" --test-id toast.customView --trace-output "$TOAST_TRACES")"
echo "$CUSTOM_TOAST"
echo "$CUSTOM_TOAST" | grep -q "toastKind=custom-view" \
  || { echo "FAIL: a Toast.setView toast must be marked custom-view, got: $CUSTOM_TOAST"; exit 1; }
echo "$CUSTOM_TOAST" | grep -q "node in the tree" \
  || { echo "FAIL: a custom-view toast must point at where its text IS, got: $CUSTOM_TOAST"; exit 1; }
R ui compact --live --package "$PKG" | grep -q "Custom view: amount exceeds your limit" \
  || { echo "FAIL: an app-drawn toast IS a node; the tree must carry its text"; exit 1; }
sleep 4
# 3. A WindowManager overlay is not a Toast at all: it never enters the queue, and
# it needs no help — it is an ordinary node.
OVERLAY="$(R act tap --package "$PKG" --test-id toast.overlay)"
echo "$OVERLAY"
echo "$OVERLAY" | grep -q "toast=" \
  && { echo "FAIL: an app overlay is not a Toast and must not be reported as one, got: $OVERLAY"; exit 1; }
R ui compact --live --package "$PKG" | grep -q "Overlay: amount exceeds your limit" \
  || { echo "FAIL: an app overlay must be an ordinary node in the tree"; exit 1; }
sleep 4
# 4. `trace log` leads with the transient message, and the empty-diff line stops
# implying the gesture missed once a toast has proved it did not.
TOAST_LOG="$(R trace log "$TOAST_TRACES")"
echo "$TOAST_LOG"
echo "$TOAST_LOG" | grep -q '! transient message shown: "Amount exceeds your daily limit"' \
  || { echo "FAIL: trace log must lead the step with the toast; got: $TOAST_LOG"; exit 1; }
echo "$TOAST_LOG" | grep -q "(no other observable change between before and after)" \
  || { echo "FAIL: with a toast recovered, the empty diff must stop reading as a miss"; exit 1; }

echo "== REFORMATTING FIELDS: type reports what LANDED, not what was sent =="
# `chars=N` counts characters SENT. The measured failure is a five-character
# --text that left three in the field, exit code 0, focus correct — a TextWatcher
# that reformats and re-lays-out on every change losing part of the `input text`
# burst. So `type` reads the field back.
open_scenario scenario.reformattingField reformat.amount
# 1. A field that LOSES part of a burst: the shortfall is detected, named, and
# re-sent over the clipboard (one change, not a run of keystrokes).
LOSSY="$(R act type --package "$PKG" --test-id reformat.lossy --text "10000")"
echo "$LOSSY"
echo "$LOSSY" | grep -q "recovery=" \
  || { echo "FAIL: a partial landing must be detected and named, got: $LOSSY"; exit 1; }
echo "$LOSSY" | grep -q "textLanded=exact" \
  || { echo "FAIL: the clipboard re-send must land the whole string, got: $LOSSY"; exit 1; }
echo "$LOSSY" | grep -q "text=10000" \
  || { echo "FAIL: the recovered field must hold the typed text, got: $LOSSY"; exit 1; }
R ui compact --live --package "$PKG" | grep -q "10000" \
  || { echo "FAIL: the tree must agree with what type reported"; exit 1; }
# 2. `--type-delay` is the escape hatch that avoids the loss instead of recovering
# from it, and the field it types into FORMATS what it is given: every character
# arrived, the app added separators. That is not a loss and must not be retried.
#
# Paced on purpose. A burst into this field is lossy too on a software-GPU
# emulator (its watcher re-lays-out the bound rows above it on every keystroke —
# the real thing, measured here at 4 of 5 characters), so pacing is what isolates
# "the app formatted it" from "the burst was cut short".
FORMATTED="$(R act type --package "$PKG" --test-id reformat.amount --text "30000" --type-delay 200)"
echo "$FORMATTED"
echo "$FORMATTED" | grep -q "paced 200ms/char" \
  || { echo "FAIL: --type-delay must report the paced path, got: $FORMATTED"; exit 1; }
echo "$FORMATTED" | grep -q "textLanded=reformatted" \
  || { echo "FAIL: an app's own formatting must read as reformatted, got: $FORMATTED"; exit 1; }
echo "$FORMATTED" | grep -q "text=30,000" \
  || { echo "FAIL: type must report the text the field actually holds, got: $FORMATTED"; exit 1; }
echo "$FORMATTED" | grep -q "recovery=" \
  && { echo "FAIL: reformatting is the app doing its job — nothing to recover, got: $FORMATTED"; exit 1; }
# 3. Into a field that ALREADY holds text there is no recovery to be had: `type`
# inserts at the caret, so clearing it would throw away content the caller never
# asked to lose. The shortfall is reported instead of repaired.
PARTIAL="$(R act type --package "$PKG" --test-id reformat.lossy --text "246813")"
echo "$PARTIAL"
echo "$PARTIAL" | grep -q "textLanded=partial" \
  || { echo "FAIL: a burst into a non-empty lossy field must read as partial, got: $PARTIAL"; exit 1; }
echo "$PARTIAL" | grep -q "landedChars=" \
  || { echo "FAIL: a partial landing must say how much landed, got: $PARTIAL"; exit 1; }
echo "$PARTIAL" | grep -q "recovery=" \
  && { echo "FAIL: a non-empty field must not be cleared to retry, got: $PARTIAL"; exit 1; }
# 4. A native field's HINT is projected, and a field already at its maxLength says
# why nothing landed. Both were measured on a real form as screenshot-only facts:
# `text="880 977 267"` with no hint channel is ambiguous (prefilled value, or a
# prompt showing through an empty field?), and a `type` into a full field reported a
# bare `textLanded=none` — indistinguishable from a tool failure.
CAPPED_TREE="$(R ui compact --live --package "$PKG")"
echo "$CAPPED_TREE" | grep -q '#reformat.capped .*"880 977 267" .*placeholder:"Phone"' \
  || { echo "FAIL: a native hint must project as placeholder, beside the value"; echo "$CAPPED_TREE"; exit 1; }
echo "$CAPPED_TREE" | grep -q '#reformat.amount .*placeholder:"Amount"' \
  || { echo "FAIL: an EMPTY native field's hint must project too"; exit 1; }
FULL="$(R act type --package "$PKG" --test-id reformat.capped --text "123")"
echo "$FULL"
echo "$FULL" | grep -q "textLanded=none" \
  || { echo "FAIL: nothing can land in a field at its maxLength, got: $FULL"; exit 1; }
echo "$FULL" | grep -q "textLandedReason=at-maxLength(11)" \
  || { echo "FAIL: a full field must say WHY nothing landed, got: $FULL"; exit 1; }
echo "$FULL" | grep -q "recovery=" \
  && { echo "FAIL: a full field cannot be recovered by re-sending, got: $FULL"; exit 1; }
# And the hint is a --label handle now, like a DOM placeholder already was.
R act tap --package "$PKG" --label "Phone" >/dev/null \
  || { echo "FAIL: a native hint must be resolvable by --label"; exit 1; }

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
# The tap that used to be silent: aim at the covered button WITH the keyboard up.
# It resolves, it dispatches, it reports settled — and the IME takes the touch. The
# warning is the whole point; without it this is indistinguishable from a tap that
# worked, which is how a flow ends up "clicking" a button nobody ever pressed.
OCCLUDED_TAP="$(R act tap --package "$PKG" --test-id login.submitButton)"
echo "$OCCLUDED_TAP"
echo "$OCCLUDED_TAP" | grep -q "occluded:keyboard" \
  || { echo "FAIL: a tap under the IME must warn that the keyboard receives the touch"; exit 1; }
echo "$OCCLUDED_TAP" | grep -q "act hide-keyboard" \
  || { echo "FAIL: the obstruction warning must name the command that clears it"; exit 1; }
sleep 1
R ui report --package "$PKG" --output "$TMP/login-occluded"
R ui compact "$TMP/login-occluded/snapshot.json" | grep -q "Logged in: 123456" \
  && { echo "FAIL: the keyboard-covered tap logged in — the premise of the warning is wrong"; exit 1; }

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

# `--clear` empties the field first, and PROVES it did. The flag used to be
# accepted and ignored: typing "2222" over a field holding "111111" left
# "1111112222" while the result read like a clean write, and a field already at
# its maxLength reported `textLanded=none` with no mention that the clear had not
# happened.
open_scenario scenario.login login.codeField
R act tap --package "$PKG" --test-id login.codeField >/dev/null
sleep 1
# An empty field says so instead of claiming deletes it did not make.
FIRST_CLEAR="$(R act type --package "$PKG" --test-id login.codeField --text "111111" --clear)"
echo "$FIRST_CLEAR"
echo "$FIRST_CLEAR" | grep -q "cleared=already-empty" \
  || { echo "FAIL: --clear on an empty field must report already-empty"; exit 1; }
CLEAR_OUT="$(R act type --package "$PKG" --test-id login.codeField --text "2222" --clear)"
echo "$CLEAR_OUT"
echo "$CLEAR_OUT" | grep -q "cleared=emptied(6ch)" \
  || { echo "FAIL: --clear must report emptying the six characters that were there"; exit 1; }
echo "$CLEAR_OUT" | grep -q "text=2222" \
  || { echo "FAIL: the field must hold exactly what was typed after --clear, not the old value plus it"; exit 1; }
echo "$CLEAR_OUT" | grep -q "textLanded=exact" \
  || { echo "FAIL: the read-back after --clear must be exact"; exit 1; }
R act hide-keyboard --package "$PKG" >/dev/null

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
# Same silence, one layer up: a tap on the trigger BEHIND the dialog resolves by
# test id and is swallowed by the dialog window. `ui compact` already marks the
# node occluded-by; the act path must say it too, naming the window rather than the
# node so the caller knows what to dismiss.
BEHIND_TAP="$(R act tap --package "$PKG" --test-id dialog.trigger)"
echo "$BEHIND_TAP"
echo "$BEHIND_TAP" | grep -q "occluded:window" \
  || { echo "FAIL: a tap on a node behind a dialog window must warn that the window takes the touch"; exit 1; }

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
