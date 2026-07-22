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
reticle --target ios ui regions out/snapshot.json
reticle --target ios act activate --package <bundle-id> --test-id <id>
reticle --target ios act tap --package <bundle-id> --test-id <id> --region "Privacy"
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

## Multi-region controls (iOS channels)

The same collapse Android suffers exists on iOS — UILabel has no native link
handling, so real agreement rows ship as YYText-style self-drawn labels or
`UITextView` attributed text, and both report as ONE node. `RegionProbe`
(in `ReticleKit`) decomposes them through the same protocol channels:

- **`span`** — real `.link` attribute runs, with per-line rects (a `UITextView`
  lends its own TextKit stack — exact; a `UILabel` gets an equivalent stack
  rebuilt from its attributed text and `textRect(forBounds:)`).
- **`a11yVirtual`** — child `accessibilityElements` a view exposes (the YYText
  pattern). The view's own whole-text proxy element is filtered out.
- **`colorSpan`** — a minority-colored `.foregroundColor` run that is not a real
  link ("highlight = tappable"), surfaced with its actual color.
- **`textMarker`** — script-agnostic bracketed (`«…»`, `《…》`, …) / markdown
  links on a self-drawn label, one region per marker, fired only for a
  user-interaction-enabled label flagged `suspectedMultiRegion`.
- **char grid** — exact per-character boundary X per line fragment for any
  UILabel/UITextView text, so `act tap --region "User Agreement"` resolves a
  plain phrase with no markers at all.

`act tap --region` resolves a discovered region's rect first, then falls back to
locating the substring through the char grid — same semantics as Android.
`act activate` additionally resolves `axElement` nodes (SwiftUI content, e.g. a
`NavigationLink` row with an `.accessibilityIdentifier`) and fires the element's
own `accessibilityActivate()` — the navigation/tap path that also works on a
real device.

## WKWebView DOM

The read-only DOM bridge is ported: a WKWebView seen during the view walk stays
an opaque node on the main thread, then the server thread evaluates the shared
DOM script (`WebViewDomScript.swift`, kept in sync with the Android
`WebViewDomScript.kt`) via `evaluateJavaScript` with a 750 ms timeout and folds
the visible DOM in as `domNode` children — same element payload, `data-testid`
as `testId`, `domCssSelector` + computed-style / image metadata, page-to-screen
coordinate folding (CSS points are UIKit points, so the scale is normally 1.0).
`ui node --css "#id"` and `act tap --css "#id"` resolve exactly like Android.
On any failure (JS timeout, detached view) the WebView remains an opaque view
node — the honest L0 fallback.

Borrowing Playwright's injected-script design (not its runtime — Playwright
cannot attach to a system WKWebView), the walk additionally pierces **open
shadow roots** and **same-origin iframes**: pierced elements carry a chained
selector (`#shadow-host >>> #shadow-button`) and iframe content coordinates are
folded into page space. Cross-origin frames stay opaque. And `act activate
--css <chain>` performs an in-process DOM activation: the agent resolves the
chain in the live document, runs an actionability check (attached / visible /
enabled / receives pointer events — honest reasons on failure), then dispatches
the full `pointerdown → mousedown → pointerup → mouseup → click` sequence. This
needs no HID surface, so it is the web-content tap path for real devices (and
for any simulator where the private HID path can't initialize).

Web pages also emit **evidence**: on first observation the agent installs
passthrough hooks (console.*, uncaught errors / unhandled rejections, fetch /
XHR timing) into each WKWebView. Events buffer in an in-page ring and drain
into `/logs` on every observation as `web_console` / `web_error` /
`web_network` entries with structured metadata (url, method, status,
durationMs). Honest boundaries: collection starts at the first observation of
a page (earlier events are absent); a document-start `WKUserScript` covers
later navigations from their start; main-frame only for the immediate install.

## Action traces (evidence packages)

Every `act` (tap / swipe / drag / type / activate) can emit a per-action
**evidence package**, the same shape Android produces, so an iOS action feeds the
`reticle serve` timeline and web panel identically. Pass `--trace-output <dir>`
(or just have a daemon running — one-shot commands auto-write into the session's
trace dir), and Reticle captures a before snapshot + screenshot, dispatches the
action, then captures an after snapshot + screenshot and writes:

```
<dir>/<millis>-<gesture>/
  before.snapshot.json  after.snapshot.json
  before.screenshot.png after.screenshot.png
  trace.json            # manifest: gesture, selector, target, result, and a
                        # compact before/after diff (the observable change)
```

The `trace.json` diff is the honest proof an action *landed* — e.g. a Pay-button
tap records `checkout.status: "Cart: 3 items" → "Paid!"`. When `reticle serve` is
running the trace publishes as an `action.trace` event targeted `ios:<pkg>`; the
manifest carries `platform: "ios"` so the daemon labels it correctly. The diff is
platform-neutral and matches `reticle-core`'s `ActionTraceDiff` field-for-field.

## Network capture (proxy / MITM / mock)

`reticle serve --target ios` puts iOS on the same host-side capture proxy as
Android — `network.*` events, HTTPS MITM, and session mocks — within the same
no-hook boundary (whistle's ceiling: no pinning bypass, no in-app trust
injection). Two host-side actions replace Android's `adb`:

Routing is never auto-applied — an iOS target has no per-app proxy hook, so it
means either the macOS *system* proxy (simulator) or the phone's Wi-Fi proxy
(device), both host/device-wide settings whose blast radius (and the risk of
stranding on a dead port if the daemon dies) is the user's to accept. `serve
--proxy-device` prints the exact steps for the target; you run and revert them.

**Simulator** (`--proxy-bind` defaults to `127.0.0.1`; the sim shares the host
network):

```
reticle serve --target ios --serial <udid> \
  --proxy-mitm true --proxy-install-ca true --proxy-ssl-hosts example.com \
  --proxy-device true
```

- CA trust is automatic with `--proxy-install-ca` — the MITM root is trusted in
  the booted simulator via `xcrun simctl keychain <udid> add-root-cert`.
- The hint prints the `networksetup -setwebproxy / -setsecurewebproxy` set +
  off commands for the active network service.

**Real device** — the phone reaches the Mac over the LAN, so bind the proxy to
the LAN with `--proxy-bind 0.0.0.0` (an explicit opt-in — it exposes the MITM
proxy on the network for the run):

```
reticle serve --target ios --serial <ecid> --proxy-bind 0.0.0.0 \
  --proxy-mitm true --proxy-ssl-hosts example.com --proxy-device true
```

The hint then prints device-side steps: set the phone's Wi-Fi proxy to the Mac's
LAN IP + port, and install + trust the CA as a profile (`--proxy-install-ca` is
simulator-only — on a device get the `.cer` onto the phone, install it under
VPN & Device Management, then enable full trust under Certificate Trust
Settings). Verified on an iPhone 13 Pro Max / iOS 26: a Safari fetch of
`https://example.com` surfaced a decrypted `GET … 200` event targeted
`ios:<ecid>`.

MITM decryption is allowlist-gated (`--proxy-ssl-hosts host,*.host`) on both;
hosts not listed pass through as opaque CONNECT tunnels. Captured traffic is
attributed to `ios:<udid|ecid>` in the timeline.

## Building & running

```
swift build --package-path reticle-host                 # the reticle host CLI
scripts/build-ios-agent.sh                              # the agent + injection dylib
scripts/build-sample-ios.sh SampleApp dev.reticle.sampleios   # a demo .app
scripts/e2e-ios.sh                                      # full simulator round trip
scripts/e2e-ios-device.sh <team-id>                     # full REAL-DEVICE round trip (linked path)
scripts/inject-ios-device.sh <identity> <bundle> <app>  # inject into a dev-signed device debug build
```

### Linking `ReticleKit` (the recommended real-device path)

An app links the agent and calls `Reticle.start()` once at launch — the iOS
analogue of linking the Android AAR:

- **SwiftPM**: add the `reticle-agent/ios` package and depend on the `ReticleKit`
  product (this is how `sample-app-ios` does it).
- **CocoaPods** (e.g. a KMP iOS app): two local podspecs ship for this —
  `reticle-swift/ReticleProtocol.podspec` and `reticle-agent/ios/ReticleKit.podspec`.
  Add them Debug-only and gate the start call to your non-production config:

  ```ruby
  # Podfile (inside your app target)
  pod 'ReticleProtocol', :path => '<reticle>/reticle-swift',      :configurations => ['Debug']
  pod 'ReticleKit',      :path => '<reticle>/reticle-agent/ios',  :configurations => ['Debug']
  ```
  ```swift
  // AppDelegate.didFinishLaunching — note some projects define TEST (not DEBUG)
  // for their debug config; gate on whatever their non-production flag is.
  #if DEBUG || TEST
  import ReticleKit
  _ = Reticle.start()
  #endif
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
- **`DYLD_INSERT_LIBRARIES` injection is simulator-only; real-device injection
  needs a Mach-O rewrite of a dev-signed debug build.** The built-in `app inject`
  (DYLD via `SIMCTL_CHILD_*`) is a simulator mechanism. A **production / App-Store
  build cannot be injected on a device at all** — no `get-task-allow`, library
  validation on, foreign team; that is Apple's security model, not a Reticle
  limit. But a **debug build you sign yourself** has `get-task-allow=true`, and
  that build *can* be injected without touching its source (validated on a real
  device, iPhone 13 Pro Max / iOS 26.0). Two routes that DON'T work on a
  device: `DYLD_INSERT_LIBRARIES` passed via `devicectl … --environment-variables`
  (the iOS launch path strips `DYLD_*` even for get-task-allow apps) and lldb
  `dlopen` (blocked on iOS 26). The route that works — `scripts/inject-ios-device.sh`
  — builds `ReticleInjection.framework` for device, embeds it in the `.app`, adds
  an `LC_LOAD_DYLIB` to the main binary (`scripts/macho_add_load.py`, needs
  `lief`) so dyld loads it as a normal dependency, then re-signs the framework
  AND the bundle with the **same identity** the app already uses (matching Team ID
  ⇒ library validation passes), reinstalls, and launches with `RETICLE_PORT` set
  (satisfies the injection autostart gate). It ends `runtime: healthy` over the
  same USB tunnel as the linked path. Still, injection re-signs the bundle (same
  effort as linking) and is more fragile — prefer the linked path; reach for
  injection only to drive a debug build whose source you can't or won't edit.
- **The real-device linked path** is validated (iPhone 13 Pro Max, iOS 26): build +
  sign the app, install/launch via `devicectl`, trust the developer cert
  on-device, then tunnel the agent port over USB with
  `iproxy -u <udid> <port>:<port>` (a device's loopback is not the host's).
  `status / ui report / ui compact / ui screenshot / act activate / mutate /
  debug logs` and the **action-trace evidence package** all work over that
  tunnel; screenshots come from the agent's in-process render. See
  `scripts/e2e-ios-device.sh`. Two device gotchas the script handles: use the
  hardware **ECID** as the device id (`idevice_id -l`) — it is the one id that
  works for `xcodebuild -destination`, `devicectl`, and `iproxy` alike (the
  `devicectl list devices` coredevice UUID does not match an xcodebuild
  destination) — and the device must be **unlocked** to launch (a locked or
  slept device rejects `devicectl process launch` and suspends the app). A free
  developer account caps installs at 3 apps/device, and automatic signing needs
  the team's Apple ID actually signed into Xcode (a keychain cert is not enough).
- **SwiftUI addressability = accessibility.** A SwiftUI element surfaces as an
  `axElement` only when it is exposed through the platform accessibility tree
  (i.e. carries `.accessibilityIdentifier(...)` / a label). Elements with no
  accessibility identity are **not** addressable — a documented contract, not a
  bug — exactly like the Android Compose-semantics boundary. The accessibility
  runtime must be engaged for these elements to populate. On the simulator with
  Simulator.app open it already is; on a **real device it is not by default** —
  SwiftUI builds its accessibility tree lazily, only once an accessibility client
  is active, so plain observation would capture just the raw UIKit view tree. The
  agent engages it at startup with `_AXSSetAutomationEnabled(true)` (the private
  flag XCUITest sets to expose accessibility for automation — no VoiceOver, fires
  no control), so `.accessibilityIdentifier`s (e.g. `scenario.checkout`) surface
  on the **first** device observation. Verified on an iPhone 13 Pro Max / iOS 26:
  first `ui report` after launch lists all four SwiftUI scenario buttons, no
  warm-up action needed. (Note: the sibling `_AXSSetApplicationAccessibilityEnabled`
  setter symbol does not exist in `libAccessibility` — only the *automation* pair
  `_AXSAutomationEnabled` / `_AXSSetAutomationEnabled` does.)
- **`act` input (HID) is simulator-only and a capability, not a runtime-version
  cutoff.** `CReticleSimHID` synthesizes real touch/keyboard via the private
  SimulatorKit path, reverse-engineered from Xcode 26: build a real `IOHIDEvent`
  digitizer parent + finger child (`IOHIDEventCreateDigitizerEvent` /
  `…FingerEvent` / `IOHIDEventAppendEvent`), wrap it through
  `IndigoHIDMessageForTrackpadEventFromHIDEventRef`, patch the touch-target tag
  (`0x32`) into the message, and deliver it via `SimDeviceLegacyHIDClient`
  (`-sendWithMessage:freeWhenDone:completionQueue:completion:`). Keyboard goes
  through `IndigoHIDMessageForHIDArbitrary`. Verified to land on native
  UIKit/SwiftUI controls on **iOS 26.2 and 26.3** (observable side effect, not
  just a clean send). An earlier revision built the message from
  `IndigoHIDMessageForMouseNSEvent` and delivered it over a raw `SimDeviceIO`
  mach send right; that shape *sends* without error on iOS 26.3+ but the touch
  is silently dropped (or misread as a Home gesture) — the worst failure for an
  agent that then believes it tapped. Because the correct path either lands or
  fails with an error (no silent no-op), the host guards `act tap/swipe/drag/type`
  by a **capability probe** (`reticle_sim_hid_available`), failing loudly with
  guidance to use `act activate` only when the private class/symbols are absent
  (a mismatched Xcode SimulatorKit layout) — not by iOS version. A real device
  has no HID surface regardless; use `act activate` (selector or `--css`) for
  the real-device-capable path.
- **SwiftUI `Text` with inline markdown links collapses in accessibility.** The
  whole Text surfaces as one `axElement` ("Read the Terms and Privacy") with no
  per-link child elements, so individual links inside one SwiftUI `Text` are not
  separately targetable — unlike UIKit rows, where the region probe decomposes
  them. Give each link its own `Link`/`Button` (or an
  `.accessibilityIdentifier`) to make it addressable.
- **Headless suspension.** An app launched by `simctl` on a simulator that isn't
  displayed gets suspended by the OS, which closes the agent's socket. Keep
  Simulator.app open (or hold the app foreground) for a reliable session.
- **No auth, loopback only** — same dev-machine-trusted model as Android. The
  agent auto-starts on injection or in DEBUG / when `ReticleAgentEnabled` is set,
  so it stays out of shipped release builds that merely link the framework.
