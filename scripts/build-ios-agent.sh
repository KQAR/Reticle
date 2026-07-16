#!/usr/bin/env bash
# Build the in-process iOS agent (reticle-agent/ios) against the iOS Simulator
# SDK. SwiftPM's `swift build` targets the host (macOS) by default, and the
# agent is UIKit-only, so we point both the Swift and C compilers at the
# iphonesimulator SDK/triple. Requires Xcode + an installed iOS Simulator SDK.
#
# Usage: scripts/build-ios-agent.sh [ios-deployment-target]
set -euo pipefail

DEPLOY="${1:-15.0}"
ARCH="$(uname -m)" # arm64 on Apple Silicon
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TRIPLE="${ARCH}-apple-ios${DEPLOY}-simulator"

cd "$(dirname "$0")/../reticle-agent/ios"

echo "Building reticle-agent/ios for ${TRIPLE}"
exec swift build \
  --sdk "$SDK" \
  -Xswiftc -target -Xswiftc "$TRIPLE" \
  -Xcc -target -Xcc "$TRIPLE" \
  -Xcc -isysroot -Xcc "$SDK"
