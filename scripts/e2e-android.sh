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
  local pkg="$1" needle="$2" deadline=$(( $(date +%s) + 60 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if R ui compact --live --package "$pkg" 2>/dev/null | grep -q "$needle"; then return 0; fi
    sleep 2
  done
  echo "FAIL: '$needle' never appeared on screen for $pkg within 60s"; exit 1
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
# The DOM button must land: #lottie-done sets #web-status to "Done".
R act tap --package "$PKG" --css "#lottie-done" >/dev/null
sleep 1
R ui report --package "$PKG" --output "$TMP/web-lottie-done"
R ui compact "$TMP/web-lottie-done/snapshot.json" | grep "webLottie.status" | grep -q "Done" \
  || { echo "FAIL: tapping the web lottie 'Done' button did not update the status"; exit 1; }

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
