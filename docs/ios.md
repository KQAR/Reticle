# Reticle on iOS

Reticle's iOS support inspects and drives a **running** iOS app on the
**Simulator**, plus a limited observation path on a real device via a linked
framework. It speaks the same `reticle-protocol` wire contract as Android
(`platform="ios"`), so the host commands and the panel are reused; only the
device seams differ. Select it with `--target ios`.

```
reticle --target ios devices
reticle --target ios launch  --package <bundle-id>      # linked app
reticle --target ios app inject --package <bundle-id>   # DYLD inject (simulator)
reticle --target ios status  --package <bundle-id>
reticle --target ios ui report --package <bundle-id> --output out/
reticle --target ios ui compact out/snapshot.json
reticle --target ios ui screenshot --package <bundle-id> --output shot.png
reticle --target ios mutate  --package <bundle-id> --test-id <id> --property alpha --value 0.3
```

## How it works (vs Android)

| Seam | Android | iOS |
| --- | --- | --- |
| Device control / transport | `adb` + `adb forward` | `xcrun simctl` (`devicectl` for real device); **no forward** — the simulator shares the host loopback, so the host hits `127.0.0.1:<derivedPort>` directly |
| Getting the agent into the process | linked AAR / JDWP dex inject | linked `ReticleKit` / **DYLD** inject (`DYLD_INSERT_LIBRARIES` via `SIMCTL_CHILD_*`, a C constructor calls `ReticleInjectorStart`) |
| Capture | `WindowManagerGlobal` + View reflection + Compose semantics | `UIApplication.connectedScenes` → windows → `UIView` tree + SwiftUI **accessibility** (`axElement`) |
| Input | `adb input` | private CoreSimulator HID (behind `IosInputBackend`) |
| Port | `PortMap.derivePort(applicationId)` | `PortMap.derivePort(bundleId)` — same FNV-1a, computed in Swift |

The in-process agent is `reticle-agent/ios` (SwiftPM: `ReticleKit` +
`ReticleInjection` + `CReticleBootstrap`). The host logic is native in
`reticle-host` (`IosHelperClient`), no Kotlin helper. Both share the Swift
`ReticleProtocol` (`reticle-swift`).

## Building & running

```
swift build --package-path reticle-host                 # the reticle host CLI
scripts/build-ios-agent.sh                              # the agent + injection dylib
scripts/build-sample-ios.sh SampleApp dev.reticle.sampleios   # a demo .app
scripts/e2e-ios.sh                                      # full simulator round trip
```

## Honest boundaries

- **`act` on a real device uses in-process activation, not HID.** The host cannot
  synthesize hardware input to a physical device, so `act tap --test-id X` (and
  `act activate`) resolve the control in the linked agent and fire it in-process
  (`UIControl.sendActions`, else `accessibilityActivate()`), returning
  `unsupported_activation_target` for inert views. Verified on an iPhone 13 Pro
  Max: activating the sample's UIKit button incremented its counter. This is
  limited to activatable controls (no coordinate taps, gestures, or `type` on a
  real device); use the simulator's HID path for those.
- **Injection is simulator-only.** A real device must link `ReticleKit` at build
  time (no DYLD injection).
  The real-device linked path is validated (iPhone 13 Pro Max, iOS 26): build +
  automatic-sign the app, install/launch via `devicectl`, trust the developer
  cert on-device, then tunnel the agent port over USB with
  `iproxy -u <udid> <port>:<port>` (a device's loopback is not the host's).
  `reticle --target ios status / ui report / ui screenshot / mutate` all work
  over that tunnel; screenshots come from the agent's in-process render (never a
  stray booted simulator). See `scripts/e2e-ios-device.sh`. A free developer
  account caps installs at 3 apps/device.
- **SwiftUI addressability = accessibility.** A SwiftUI element surfaces as an
  `axElement` only when it is exposed through the platform accessibility tree
  (i.e. carries `.accessibilityIdentifier(...)` / a label). Elements with no
  accessibility identity are **not** addressable — a documented contract, not a
  bug — exactly like the Android Compose-semantics boundary. Note the
  accessibility runtime must be engaged for these elements to populate; a
  strictly headless simulator (no Simulator UI, no accessibility) may expose the
  UIKit tree but not SwiftUI `axElement`s.
- **`act` input (HID) works on the simulator (Xcode 26 path).** Xcode 26 removed
  the `SimDeviceLegacyHIDClient sendWithMessage:` path that idb and comparable
  tools use, replacing it with a `SimDeviceIO` port graph. `CReticleSimHID`
  reverse-engineers the new path: `SimDeviceIOClient(device) → ioPorts →` the
  `SimLegacyHIDDescriptor` port `→ -legacyHIDEventPort` (an `OS_xpc_mach_send`)
  `→ xpc_mach_send_copy_right →` a mach send right, then a two-payload Indigo
  touch message is delivered with `mach_msg`. The `IndigoHIDMessageFor*` builders
  are still resolved from SimulatorKit by `dlsym`. Verified on-simulator: a
  synthesized tap increments the sample app's tap counter. Simulator-only (a real
  device has no HID surface) and fragile across Xcode versions by nature.
- **Headless suspension.** An app launched by `simctl` on a simulator that isn't
  displayed gets suspended by the OS, which closes the agent's socket. Keep
  Simulator.app open (or hold the app foreground) for a reliable session.
- **No auth, loopback only** — same dev-machine-trusted model as Android. The
  agent auto-starts on injection or in DEBUG / when `ReticleAgentEnabled` is set,
  so it stays out of shipped release builds that merely link the framework.
