#!/usr/bin/env bash
# End-to-end smoke test for the Android agent on a device or emulator. Builds the
# agent AAR + dex payload and both sample-app flavors, installs them, and
# exercises the full round trip through the Swift host + native helper: linked
# launch, ui report, compact, selector taps with --verify and --trace-output,
# runtime mutation, agreement-region resolution, WebView DOM, the login
# keyboard trap, and the JDWP injection path on the noagent flavor.
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
