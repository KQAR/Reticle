#!/usr/bin/env bash
# Run the in-process iOS agent's unit tests (reticle-agent/ios) on an iOS
# Simulator.
#
# Why not `swift test`: ReticleKit is UIKit-only, so SwiftPM's host-triple test
# runner cannot even build it — the same reason scripts/build-ios-agent.sh exists.
# XCTest on the simulator can, and it gives the tests real UIViews, a real
# UIWindow and real TextKit, which is what the capture code is made of.
#
# The destination is resolved at run time rather than pinned to a device name:
# the runner's Xcode decides which simulators exist, and a hard-coded
# "iPhone 16" breaks on every Xcode bump.
#
# Usage: scripts/test-ios-agent.sh [simulator-name-substring]
set -euo pipefail

WANT="${1:-iPhone}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

UDID="$(xcrun simctl list devices available --json \
  | python3 -c '
import json, sys
want = sys.argv[1].lower()
data = json.load(sys.stdin)["devices"]
best = None
for runtime, devices in sorted(data.items()):
    if "iOS" not in runtime:
        continue
    for device in devices:
        if not device.get("isAvailable"):
            continue
        if want not in device["name"].lower():
            continue
        # Prefer one that is already booted; booting costs ~30s in CI.
        if device.get("state") == "Booted":
            print(device["udid"]); sys.exit(0)
        best = best or device
if best is None:
    sys.exit("no available iOS simulator matching %r" % sys.argv[1])
print(best["udid"])
' "$WANT")"

echo "Testing reticle-agent/ios on simulator $UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || xcrun simctl boot "$UDID" || true

# -quiet keeps the log to failures + the summary; a full xcodebuild log buries a
# failing assertion under thousands of compile lines in CI.
cd "$ROOT/reticle-agent/ios"
exec xcodebuild test \
  -scheme reticle-agent-ios-Package \
  -destination "id=$UDID" \
  -derivedDataPath ".derived" \
  -quiet
