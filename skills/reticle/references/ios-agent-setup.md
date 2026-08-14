# Getting the agent into an iOS app

Read this when `--target ios` and the runtime is unreachable — nothing here is
needed once `status` reports healthy. Back to [SKILL.md](../SKILL.md).

Android's `app inject` has no iOS equivalent: there is no JDWP-shaped channel to
a running iOS process. Pick the row that matches what you have.

| You have | Route |
| --- | --- |
| Simulator, any build you can launch | `reticle --target ios app inject --package <bundle>` (DYLD via `SIMCTL_CHILD_*`), or a linked build |
| Real device, **source you can edit** | Link `ReticleKit` — recommended |
| Real device, **a debug build you signed**, source off-limits | `scripts/inject-ios-device.sh` — Mach-O rewrite + re-sign |
| Real device, production / App-Store / another team's build | **Unreachable.** Say so; do not attempt |

## Real device, linked (recommended)

Link the agent and start it once at launch. Costs one dependency plus one line,
and is far less fragile than injection.

- **SwiftPM**: depend on the `ReticleKit` product of `reticle-agent/ios` (how
  `sample-app-ios` does it).
- **CocoaPods** (e.g. a KMP iOS app): two local podspecs ship for this. Add them
  Debug-only, and gate the start call to the non-production config:

```ruby
# Podfile, inside the app target
pod 'ReticleProtocol', :path => '<reticle>/reticle-swift',     :configurations => ['Debug']
pod 'ReticleKit',      :path => '<reticle>/reticle-agent/ios', :configurations => ['Debug']
```
```swift
// AppDelegate.didFinishLaunching — some projects define TEST, not DEBUG, for
// their debug config; gate on whatever their non-production flag is.
#if DEBUG || TEST
import ReticleKit
_ = Reticle.start()
#endif
```

`scripts/e2e-ios-device.sh <team-id>` runs the whole round trip.

## Real device, injection (no source change)

```bash
scripts/inject-ios-device.sh <signing-identity> <bundle-id> <app-path> [ecid|auto]
```

Builds `ReticleInjection.framework` for device, embeds it in the `.app`, adds an
`LC_LOAD_DYLIB` to the main binary (`scripts/macho_add_load.py`) so dyld loads it
as a normal dependency, re-signs framework **and** bundle, reinstalls, launches
with `RETICLE_PORT`, and ends at `runtime: healthy`.

Check all of these before running it — each one fails the script, and three of
them fail in a way that does not name itself:

- **The build must be debug and dev-signed** (`get-task-allow=true`). Production
  and App-Store builds cannot be injected at all: no `get-task-allow`, library
  validation on, foreign team. Apple's security model, not a Reticle limit.
- **You must hold the private key of the identity the app is already signed
  with.** The framework is signed with that same identity so Team IDs match and
  library validation passes. A different identity installs nothing.
- **Re-signing reseals the entire bundle**, because the Mach-O rewrite
  invalidates the original signature — this is not "signing the Reticle
  framework". The script preserves the app's entitlements by extracting them
  first (`codesign -d --entitlements`); if that extraction comes back empty it
  falls through to an entitlement-less re-sign and the app installs but loses
  `get-task-allow`, app groups, associated domains. Verify after:
  `codesign -d --entitlements - <app>`.
- **Tools**: `iproxy` + `idevice_id` (`brew install libimobiledevice`), `python3`
  with `lief` (`pip3 install lief`), `xcodebuild`.
- **Device**: paired, Developer Mode on, the developer cert trusted on-device
  (Settings > General > VPN & Device Management), and **unlocked** at launch — a
  locked device rejects `devicectl process launch`.

Routes that do **not** work on a device, both measured — do not retry them:

- `DYLD_INSERT_LIBRARIES` via `devicectl … --environment-variables`: the iOS
  launch path strips `DYLD_*` even for get-task-allow apps.
- lldb / debugserver `dlopen`: blocked on iOS 26.

Injection re-signs the bundle, so it costs about what linking costs and breaks
more easily. Reach for it only to drive a debug build whose source you cannot
edit.

## Driving it, once it is up

A device's loopback is not the host's, so tunnel the agent port over USB:

```bash
iproxy -u <ecid> <port> <port> &
reticle --target ios ui report --package <bundle> --port <port> --output out/
```

Use the hardware **ECID** (`idevice_id -l`) as the device id everywhere — it is
the one id `xcodebuild -destination`, `devicectl` and `iproxy` all accept; the
`devicectl list devices` CoreDevice UUID does not match an xcodebuild
destination. The port is derived from the bundle id, same as on Android.

Everything here is about the app's **own** runtime. UI the app does not own — a
permission alert, SpringBoard, Home — has no route through the agent at any
setup level; that is the system channel, and it installs separately:
[ios-system-channel.md](ios-system-channel.md).

Mechanism detail, and every other real-device boundary: `docs/ios.md`.

## Authorization

Injecting into, or re-signing, an app you do not own needs explicit permission
from the owner. Re-signing a third-party bundle is the more sensitive of the
two — it touches signing material and distribution terms, not just the process.
Never let an injected build reach TestFlight or the App Store: keep the pod
Debug-only and the `Reticle.start()` call behind the non-production flag.
