#!/usr/bin/env bash
# Build the in-process iOS agent (reticle-agent/ios) against the iOS Simulator
# SDK. SwiftPM's `swift build` targets the host (macOS) by default, and the
# agent is UIKit-only, so we point both the Swift and C compilers at the
# iphonesimulator SDK/triple. Requires Xcode + an installed iOS Simulator SDK.
#
# Usage: scripts/build-ios-agent.sh [ios-deployment-target]
# The last line of output is BIN_DIR=<products dir> (libReticleInjection.dylib lives there).
set -euo pipefail

DEPLOY="${1:-18.0}"
ARCH="$(uname -m)" # arm64 on Apple Silicon
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TRIPLE="${ARCH}-apple-ios${DEPLOY}-simulator"

cd "$(dirname "$0")/../reticle-agent/ios"

echo "Building reticle-agent/ios for ${TRIPLE}"
swift build --triple "$TRIPLE" --sdk "$SDK"
# Where the products landed differs by build system (native: <triple>/debug,
# swiftbuild: out/Products/Debug-iphonesimulator), so ask rather than guess.
echo "BIN_DIR=$(swift build --triple "$TRIPLE" --sdk "$SDK" --show-bin-path)"
