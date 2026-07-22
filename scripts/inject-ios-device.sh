#!/usr/bin/env bash
# Inject the Reticle agent into an ALREADY-BUILT, dev-signed iOS debug .app on a
# REAL DEVICE — no source changes, no recompile of the target app.
#
# When to use this instead of the linked path (link ReticleKit + Reticle.start()):
# only when you cannot or will not edit + rebuild the target app from source but
# you DO have a debuggable, dev-signed build of it (get-task-allow=true). The
# linked path is simpler and is the recommended route; this exists for the
# "drive a debug build I can't touch the source of" case.
#
# Why this shape (validated on MabilisCash / iPhone 13 Pro Max / iOS 26.0):
#   - Injection is only possible because a debug build we sign has
#     get-task-allow=true (AMFI precondition). A production/App-Store build cannot
#     be injected — this is Apple's security model, not a Reticle limit.
#   - DYLD_INSERT_LIBRARIES via `devicectl ... --environment-variables` does NOT
#     work: the iOS launch path strips DYLD_* even for get-task-allow apps.
#   - lldb/debugserver `dlopen` is blocked on iOS 26 ("expression while the
#     process is connected").
#   - So we rewrite the main Mach-O with an LC_LOAD_DYLIB (dyld loads the agent
#     framework as a normal dependency), then re-sign the framework AND the app
#     bundle with the SAME identity (matching Team ID => library validation
#     passes) and reinstall.
#
# Prereqs:
#   - The target .app is a debug, dev-signed build (get-task-allow=true).
#   - Same signing setup as scripts/e2e-ios-device.sh: an Apple ID signed into
#     Xcode whose team owns the signing cert; device paired + Developer Mode on +
#     the cert trusted on-device; the device UNLOCKED at launch.
#   - Tools: xcodebuild, iproxy + idevice_id (brew install libimobiledevice),
#     python3 with lief (pip3 install lief).
#
# Usage: scripts/inject-ios-device.sh <signing-identity> <bundle-id> <app-path> [device-ecid|auto]
#   signing-identity : the codesign identity the app is ALREADY signed with,
#                      e.g. "Apple Development: Jane (ABCDE12345)" or its SHA-1.
#                      The injected framework is signed with THIS so Team IDs match.
#   bundle-id        : the app's bundle identifier (used to derive the agent port).
#   app-path         : path to the prebuilt .app to inject into (modified in place).
#   device-ecid      : hardware ECID (idevice_id -l). Defaults to `auto`.
set -euo pipefail

IDENTITY="${1:?signing identity (matches how the app is already signed)}"
BUNDLE="${2:?bundle id}"
APP="${3:?path to the prebuilt debug .app}"
DEV_ARG="${4:-auto}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${RETICLE_HOST:-$ROOT/reticle-host/.build/debug/ReticleHost}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v iproxy >/dev/null || { echo "iproxy not found (brew install libimobiledevice)"; exit 1; }
python3 -c "import lief" 2>/dev/null || { echo "lief not found (pip3 install lief)"; exit 1; }
[ -x "$HOST" ] || { echo "build the host first: swift build --package-path reticle-host"; exit 1; }
[ -d "$APP" ] || { echo "no .app at $APP"; exit 1; }

if [ "$DEV_ARG" = "auto" ]; then DEV_ECID="$(idevice_id -l 2>/dev/null | head -1)"; else DEV_ECID="$DEV_ARG"; fi
[ -n "$DEV_ECID" ] || { echo "no device (idevice_id -l empty)"; exit 1; }
# The hardware ECID works as the id for devicectl --device and iproxy -u alike
# (see docs/ios.md); no CoreDevice-UUID lookup needed.

PORT="$(python3 -c 'x=0x811C9DC5
for b in "'"$BUNDLE"'".encode(): x^=b; x=(x*0x01000193)&0xFFFFFFFF
print(8765+(x%1000))')"
echo "device ECID=$DEV_ECID  bundle=$BUNDLE  port=$PORT"

echo "== 1/6 build ReticleInjection.framework for device =="
( cd "$ROOT/reticle-agent/ios" && xcodebuild build -scheme ReticleInjection -sdk iphoneos \
    -destination 'generic/platform=iOS' -derivedDataPath "$WORK/dd" CODE_SIGNING_ALLOWED=NO -quiet )
FW="$WORK/dd/Build/Products/Debug-iphoneos/PackageFrameworks/ReticleInjection.framework"
[ -d "$FW" ] || { echo "framework build failed"; exit 1; }

echo "== 2/6 embed framework into the bundle =="
mkdir -p "$APP/Frameworks"
rm -rf "$APP/Frameworks/ReticleInjection.framework"
cp -R "$FW" "$APP/Frameworks/"

echo "== 3/6 add LC_LOAD_DYLIB to the main binary =="
MAIN="$APP/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")"
python3 "$ROOT/scripts/macho_add_load.py" "$MAIN" \
  "@executable_path/Frameworks/ReticleInjection.framework/ReticleInjection"

echo "== 4/6 re-sign framework + app (same identity => Team IDs match) =="
# Preserve the app's existing entitlements (get-task-allow, associated-domains,
# app groups, …) across the re-sign, else the resealed app loses them.
codesign -d --entitlements - --xml "$APP" 2>/dev/null > "$WORK/ent.plist" || true
codesign -f -s "$IDENTITY" --timestamp=none "$APP/Frameworks/ReticleInjection.framework"
if [ -s "$WORK/ent.plist" ]; then
  codesign -f -s "$IDENTITY" --entitlements "$WORK/ent.plist" --timestamp=none "$APP"
else
  codesign -f -s "$IDENTITY" --timestamp=none "$APP"
fi
codesign --verify --verbose=2 "$APP" >/dev/null 2>&1 && echo "signature OK"

echo "== 5/6 reinstall + launch (RETICLE_PORT satisfies the injection autostart gate) =="
xcrun devicectl device process terminate --device "$DEV_ECID" "$BUNDLE" 2>/dev/null >/dev/null || true
xcrun devicectl device install app --device "$DEV_ECID" "$APP" >/dev/null
xcrun devicectl device process launch --device "$DEV_ECID" \
  --environment-variables "{\"RETICLE_PORT\":\"$PORT\"}" "$BUNDLE" >/dev/null
echo "launched"

echo "== 6/6 tunnel + verify (app must stay foreground) =="
pkill -f "iproxy $PORT" 2>/dev/null || true
iproxy -u "$DEV_ECID" "$PORT" "$PORT" >/dev/null 2>&1 &
IPROXY=$!
trap 'kill $IPROXY 2>/dev/null; rm -rf "$WORK"' EXIT
sleep 4
"$HOST" --target ios status --package "$BUNDLE" --port "$PORT"
echo
echo "Agent is up. Drive it over the tunnel, e.g.:"
echo "  iproxy -u $DEV_ECID $PORT $PORT &"
echo "  $HOST --target ios ui report --package $BUNDLE --port $PORT --output out/"
