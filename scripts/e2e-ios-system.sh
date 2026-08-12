#!/usr/bin/env bash
# End-to-end smoke test for the iOS SYSTEM CHANNEL on a REAL DEVICE.
#
# The system channel is the out-of-process XCUITest runner: it reads and drives
# what the in-app agent structurally cannot — a system permission alert,
# SpringBoard, the Home gesture. This script covers the PREPARE段 (TC-001, TC-003
# .. TC-005, TC-007, TC-008); the READ / DRIVE / SHOT sections arrive with their
# phases.
#
# Deliberately NOT part of scripts/e2e-ios-device.sh: that script assumes the app
# under test stays in the FOREGROUND, and this channel exists partly to push it out
# of the foreground. Sharing one script would make both harder to read and one of
# them wrong.
#
# Prereqs (interactive, one-time):
#   - Device paired, Developer Mode on, UNLOCKED (Auto-Lock = Never).
#   - Settings > Developer > Enable UI Automation is ON. Without it every run fails
#     as `channel refused` / `Exiting due to IDE disconnection`, which looks like
#     anything but a missing switch. If the switch IS on and it still fails that
#     way, REBOOT the device: the automation service can wedge, and nothing short
#     of a reboot clears it.
#   - A signing team with a provisioning profile that lists this device.
#   - iproxy + idevice_id (brew install libimobiledevice).
#
# Usage: scripts/e2e-ios-system.sh <team-id> [device-udid|auto] [app-bundle-id]
set -euo pipefail

TEAM="${1:?team id (a team with a profile that lists this device)}"
DEV_ARG="${2:-auto}"
BUNDLE="${3:-dev.reticle.sampleios}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${RETICLE_HOST:-$ROOT/reticle-host/.build/debug/ReticleHost}"

command -v iproxy >/dev/null || { echo "iproxy not found (brew install libimobiledevice)"; exit 1; }
command -v idevice_id >/dev/null || { echo "idevice_id not found (brew install libimobiledevice)"; exit 1; }
[ -x "$HOST" ] || { echo "build the host first: swift build --package-path reticle-host"; exit 1; }

if [ "$DEV_ARG" = "auto" ]; then
  DEV_UDID="$(idevice_id -l 2>/dev/null | head -1)"
else
  DEV_UDID="$DEV_ARG"
fi
[ -n "$DEV_UDID" ] || { echo "no device found (idevice_id -l empty)"; exit 1; }

export RETICLE_RUNNER_PROJECT="${RETICLE_RUNNER_PROJECT:-$ROOT/reticle-runner-ios/ReticleRunner.xcodeproj}"
SYS=("$HOST" "system" "--target" "ios" "--serial" "$DEV_UDID" "--package" "$BUNDLE")

echo "device: $DEV_UDID  team: $TEAM  app: $BUNDLE"

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_contains() { # haystack needle label
  case "$1" in *"$2"*) echo "  ok: $3" ;; *) fail "$3 — expected '$2' in: $1" ;; esac
}
expect_missing() {
  case "$1" in *"$2"*) fail "$3 — did NOT expect '$2' in: $1" ;; *) echo "  ok: $3" ;; esac
}

# The device must be unlocked, and this is worth failing on EARLY: a locked device
# produces failures that read like automation problems (TC-006 covers the message
# itself, manually).
if xcrun devicectl device info lockState --device "$DEV_UDID" 2>/dev/null | grep -q "passcodeRequired: true"; then
  fail "device is LOCKED — unlock it and set Auto-Lock = Never"
fi

echo
echo "== PREPARE =="

# TC-003: an unusable team must be refused BEFORE anything is built, and the
# refusal must list what would work instead.
echo "-- TC-003: unusable signing team is refused and usable ones are listed"
OUT="$("${SYS[@]}" prepare --team ZZZZINVALID 2>&1 || true)"
expect_contains "$OUT" "signing" "refusal names signing material"
expect_missing "$OUT" "BUILD SUCCEEDED" "nothing was built for a bad team"

# TC-001: prepare reaches `installed`, and reports the device it used.
echo "-- TC-001: prepare installs the runner"
OUT="$("${SYS[@]}" prepare --team "$TEAM" 2>&1)" || fail "prepare failed: $OUT"
expect_contains "$OUT" "state=installed" "prepare reports installed"
expect_contains "$OUT" "$DEV_UDID" "prepare reports the device"

# TC-005: a second prepare REPLACES the existing install and says so, rather than
# leaving two copies and an unanswerable "which one answered?".
echo "-- TC-005 / TC-007: re-prepare replaces rather than coexists"
OUT="$("${SYS[@]}" prepare --team "$TEAM" 2>&1)" || fail "second prepare failed: $OUT"
expect_contains "$OUT" "replaced=previous-install" "replacement is declared"
COUNT="$(xcrun devicectl device info apps --device "$DEV_UDID" 2>/dev/null \
         | grep -c "dev.reticle.runner.xctrunner" || true)"
[ "$COUNT" = "1" ] || fail "TC-007 — expected exactly 1 runner install, found $COUNT"
echo "  ok: exactly one runner install on the device"

# TC-001 (second half): a later session must not rebuild. `status` is enough to
# prove the channel is usable without a build step.
echo "-- TC-001: a later session needs no rebuild"
OUT="$("${SYS[@]}" status 2>&1)" || fail "status failed: $OUT"
expect_contains "$OUT" "system: installed" "status reports installed"
expect_missing "$OUT" "BUILD" "status builds nothing"

echo
echo "== READ =="

# TC-011: an explicitly named target is readable, and a big one must come back
# TRUNCATED-and-said-so rather than complete-looking. Home is the reliably large
# target (measured: 300+ nodes).
echo "-- TC-011: explicit target reads, and declares truncation when it hits the ceiling"
OUT="$("${SYS[@]}" tree home 2>&1)" || fail "tree home failed: $OUT"
expect_contains "$OUT" "channel=system-runner" "result names the channel"
expect_contains "$OUT" "process=com.apple.springboard" "result names the process it is about"
case "$OUT" in
  *truncated:*) echo "  ok: truncation is declared with returned/limit" ;;
  *) echo "  note: home fit under the ceiling on this device — truncation not exercised" ;;
esac

# TC-012: what this channel cannot see must NAME itself. An empty field would read
# as "the app has nothing there", which is the opposite of the truth.
echo "-- TC-012: unreadable properties name themselves"
expect_contains "$OUT" "unreadable by this channel" "blind spots are stated"
expect_contains "$OUT" "isVisible" "isVisible is declared unreadable, not silently absent"

# TC-015: a vanished runner is restarted once AND the restart is declared, because
# it takes the foreground away from whatever was there.
echo "-- TC-015: a mid-read runner death is recovered and declared"
RUNNER_PID="$(xcrun devicectl device info processes --device "$DEV_UDID" 2>/dev/null \
              | awk '/ReticleRunner-Runner/ {print $1; exit}')"
if [ -n "${RUNNER_PID:-}" ]; then
  xcrun devicectl device process signal --device "$DEV_UDID" --signal SIGKILL --pid "$RUNNER_PID" >/dev/null 2>&1 || true
  OUT="$("${SYS[@]}" tree home 2>&1)" || fail "read after runner death failed: $OUT"
  expect_contains "$OUT" "runner-started-mid-command" "the restart is on the evidence"
else
  echo "  note: could not find a live runner pid to kill — TC-015 not exercised"
fi

# TC-009 / TC-010 need a specific on-screen state and are left to the operator:
# forcing a system alert would mean driving whatever prompt this device happens to
# have, which is not something a smoke test should do to someone's phone.
echo "-- TC-009 / TC-010: see the MANUAL section"

echo
echo "== DRIVE =="

# TC-021: an out-of-bounds coordinate is refused BEFORE dispatch, and the refusal
# names the screen it was measured against.
echo "-- TC-021: out-of-bounds coordinates are refused"
OUT="$("${SYS[@]}" tap --point 9999,9999 2>&1)" || fail "tap refusal returned non-zero: $OUT"
expect_contains "$OUT" "refused" "the tap is refused, not dispatched"
expect_contains "$OUT" "outside the" "the refusal names the screen bounds"

# TC-020: a target that is not on screen is refused WITH what is actually there.
# A bare "not found" cannot distinguish a typo from a screen that moved on.
echo "-- TC-020: an unknown label is refused and the real options are listed"
OUT="$("${SYS[@]}" tap --label "ReticleNoSuchControl" 2>&1)" || fail "label refusal returned non-zero: $OUT"
expect_contains "$OUT" "refused" "the tap is refused"
expect_contains "$OUT" "available=" "the refusal lists what IS on the system layer"

# TC-017: Home is dispatched against SpringBoard. The app-side side effect is the
# caller's to verify, which is why this result says `changed=unchecked` rather
# than claiming an effect it did not measure.
echo "-- TC-017: home is dispatched and does not overclaim"
OUT="$("${SYS[@]}" home 2>&1)" || fail "home failed: $OUT"
expect_contains "$OUT" "dispatched via=home" "home is dispatched"
expect_missing "$OUT" "changed=yes" "home does not claim an effect it did not measure"

# TC-018: activate brings the app forward WITHOUT restarting it. The evidence is
# `via=activate` — the runner reports `via=activate:was-not-running` when it had to
# start a stopped app, so the plain form means the process was already alive.
echo "-- TC-018: activate brings the app forward without relaunching it"
OUT="$("${SYS[@]}" activate --package "$BUNDLE" 2>&1)" || fail "activate failed: $OUT"
expect_contains "$OUT" "via=activate" "activate is dispatched"
expect_missing "$OUT" "was-not-running" "the app was already running — it was not relaunched"
expect_contains "$OUT" "process=$BUNDLE" "the result names the app it acted on"

# TC-019 / TC-022 need a known-inert spot on a known screen, which varies per
# device; see the MANUAL section.
echo "-- TC-019 / TC-022: see the MANUAL section"

echo
echo "== STOP =="

# TC-004: stopping releases the channel and leaves the device's foreground alone.
echo "-- TC-004: stop releases the channel"
OUT="$("${SYS[@]}" stop 2>&1)" || fail "stop failed: $OUT"
expect_contains "$OUT" "system stopped" "stop confirms"
OUT="$("${SYS[@]}" status 2>&1)"
# Match the STATE token, not a bare "connected": the advice line legitimately
# contains the word ("installed but not connected"), so a substring check here
# fails on correct output.
expect_missing "$OUT" "system: connected" "channel is no longer connected"

# TC-008: stopping something already stopped is SUCCESS — it is the state the
# caller asked for, and an error here would push callers toward ignoring failures.
echo "-- TC-008: stopping an already-stopped channel succeeds"
OUT="$("${SYS[@]}" stop 2>&1)" || fail "idempotent stop returned non-zero: $OUT"
expect_contains "$OUT" "nothing was running" "no-op stop says so plainly"

echo
echo "== MANUAL (not automated: they require breaking a precondition) =="
cat <<'MANUAL'
  TC-002  Turn OFF Settings > Developer > Enable UI Automation, then run any
          `system` command. It must name that switch and must NOT surface raw
          tool output (`exit 74`, `dtxproxy`, `IDE disconnection`).
          Turn it back ON afterwards.
  TC-006  Lock the device, then run `system prepare`. It must say the device needs
          to be unlocked, and must fail fast rather than hanging until a timeout.
  TC-009  With a system permission alert up (e.g. run the sample app's `permission`
          scenario and trigger it), run `system overlay`. It must return the alert's
          title, body and BOTH buttons, each with a frame and hittability.
  TC-010  With nothing covering the app, run `system overlay`. It must print
          "overlay: none" — a positive answer, not an empty tree.
  TC-019  On the Home screen, `system tap --point <x,y>` on an empty patch. It must
          report `dispatched … process=com.apple.springboard`, and Home must stay up.
  TC-022  Tap that same inert spot again. The result must read `changed=no
          (dispatched, but nothing observably changed)` — never "success".
MANUAL

echo
echo "ALL AUTOMATED SYSTEM-CHANNEL CHECKS PASSED"
