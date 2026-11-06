#!/usr/bin/env bash
# Round trip for the iOS SYSTEM CHANNEL's host backend on a REAL DEVICE: nothing
# installed on the phone, every command one CoreDevice tunnel (`reticle-device`).
# (`e2e-ios-system.sh` is the same surface through the XCUITest runner.)
#
#   scripts/e2e-ios-host-system.sh [<device-udid>] [<bundle-id>]
#
# Needs: the device on USB, unlocked, trusted, developer mode on; the sample app
# installed (scripts/e2e-ios-device.sh installs it); `reticle-device` built
# (cargo build --release --manifest-path reticle-device/Cargo.toml).
#
# It sends the app under test to the background (Home) and brings it back, and it
# dismisses nothing it did not raise: if a system modal is already up, the run
# stops and says so, because tapping someone else's alert is not this script's call.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${RETICLE_HOST:-$ROOT/reticle-host/.build/debug/ReticleHost}"
UDID="${1:-$(idevice_id -l 2>/dev/null | head -1)}"
BUNDLE="${2:-dev.reticle.sampleios}"
[ -x "$HOST" ] || { echo "build the host first: swift build --package-path reticle-host"; exit 1; }
[ -n "$UDID" ] || { echo "no device found (idevice_id -l empty)"; exit 1; }
SYS=("$HOST" system --target ios --serial "$UDID")
TMP="$(mktemp -d)"

fail() { echo "FAIL: $*" >&2; exit 1; }
expect() { # haystack needle label
  case "$1" in *"$2"*) echo "  ok: $3" ;; *) fail "$3 — expected '$2' in: $1" ;; esac
}

echo "== STATUS =="
OUT="$("${SYS[@]}" status)"; echo "$OUT"
expect "$OUT" "system: ready channel=host" "the tunnel and every service the channel needs are there"

echo "== OVERLAY (precondition) =="
OUT="$("${SYS[@]}" overlay)"; echo "$OUT"
case "$OUT" in
  *"overlay: none"*) echo "  ok: nothing is covering the screen" ;;
  *) fail "a system modal is already up; answer it on the phone (or with \`system tap --label\`) and rerun" ;;
esac

echo "== HOME =="
OUT="$("${SYS[@]}" home)"; echo "$OUT"
expect "$OUT" "dispatched via=home" "Home is dispatched"
sleep 1
OUT="$("${SYS[@]}" tree home)"; echo "$OUT" | head -5
expect "$OUT" "process=com.apple.springboard" "SpringBoard is in front after Home"
expect "$OUT" "unrecognized:44" "the home screen reads as icons"

echo "== REFUSALS =="
OUT="$("${SYS[@]}" tap --label "reticle-no-such-control")"; echo "$OUT"
expect "$OUT" "refused via=label:reticle-no-such-control" "a missing label is refused, not dispatched"
OUT="$("${SYS[@]}" tree "$BUNDLE" 2>&1 || true)"; echo "$OUT"
expect "$OUT" "is not in front" "an app that is not in front is refused with what is"

echo "== ACTIVATE =="
OUT="$("${SYS[@]}" activate --package "$BUNDLE")"; echo "$OUT"
expect "$OUT" "dispatched via=activate process=$BUNDLE changed=yes" "the app comes back to the front"
OUT="$("${SYS[@]}" tree "$BUNDLE")"; echo "$OUT" | head -5
expect "$OUT" "channel=system-host process=$BUNDLE" "the app's own tree is read by name"

echo "== POINT TAP =="
# The app's top-left corner holds no control in any scenario; the point is that a
# coordinate tap is dispatched and its before/after comparison is reported.
OUT="$("${SYS[@]}" tap --point 5,5)"; echo "$OUT"
expect "$OUT" "dispatched via=point:5,5" "a coordinate tap is dispatched"
OUT="$("${SYS[@]}" tap --point 5000,5 || true)"; echo "$OUT"
expect "$OUT" "outside the" "an off-screen coordinate is refused"

echo "== SCREENSHOT =="
OUT="$("${SYS[@]}" screenshot --out "$TMP/shot.png")"; echo "$OUT"
expect "$OUT" "via=system-host:display" "the picture names its source"
file "$TMP/shot.png" | grep -q "PNG image" || fail "not a PNG"

echo "== OK =="
