# Changelog

## Unreleased

- iOS: fixed in-process screenshots going permanently black after the first
  keyboard appearance. `ScreenshotCapture` composited every attached window
  into one opaque context; the keyboard's system window (`UITextEffectsWindow`)
  attaches to the scene on first text focus, never detaches, and its content is
  not renderable in-process — `drawHierarchy` black-filled the full-screen rect
  over the app content on every subsequent capture. Each window now renders
  into its own transparent layer and only layers whose `drawHierarchy` reports
  success are composited, so an unrenderable system window is skipped honestly
  instead of covering the app. Found by replaying a recorded flow that types
  into a text field — every frame after the keyboard step was black.

- Host: new `reticle replay gif <trace-dir>` — the first evidence-workflow
  product (A4 on the roadmap). It stitches the action-trace packages a flow
  recorded with `act … --trace-output` into a device-framed animated GIF:
  each step contributes its before-screenshot (with the gesture drawn where the
  input landed — a ring at the resolved tap point, an arrow for a swipe/drag
  stroke) and its after-screenshot (captioned with the diff change count), with
  step captions built from the trace's gesture + selector. Works on Android and
  iOS traces alike (one manifest reader covers both), is host-local (reads
  evidence already on disk, never touches a device), and renders with
  ImageIO/CoreGraphics only — no new dependencies. Marker geometry is scaled
  through the snapshot's `screen.size.width`, not the screenshot's pixel width
  — on iOS the gesture coordinates are points while the screenshot is device
  pixels (caught by replaying a real simulator trace; a pixel-space mapping
  drew the tap ring at ⅓ of the true position), while on Android the two
  spaces coincide and nothing changes. Steps without screenshots
  are skipped with a stderr note, never fabricated. Options: `--output`
  (default `<trace-dir>/replay.gif`), `--width`, `--frame-ms`. Covered by unit
  tests over synthetic traces and a step in `scripts/e2e-ios.sh` that replays
  the real recorded checkout tap.

- Host: the network capture lane — proxy, MITM, certificate store, body store,
  and `NetworkMockStore` — is now its own `ReticleNetworkLane` SwiftPM target
  instead of living mixed into `ReticleHostCore`. It depends only on a new
  dependency-free `ReticleHostShared` layer (`JSONValue` / event models /
  `HelperError`) plus SwiftNIO, and reaches the session store through a single
  `NetworkEventSink` protocol (`emit` + `sessionDirectory`) rather than
  referencing `EventStore` directly — the compiler-enforced realization of the
  "proxy backend behind an interface" roadmap goal, so the lane builds and tests
  without the daemon and swapping the engine later means editing one target.
  `ReticleHostCore` `@_exported`s the two lower targets, so it is an internal
  boundary with no change to the public API or the CLI. No behavior change.
- Host: new `scripts/e2e-proxy.sh` end-to-end smoke test (host-only, no device)
  covering the whole network lane over real sockets — `reticle serve` with the
  proxy, mock rules set through the `reticle mock` CLI, a plaintext mock hit, an
  HTTPS mock hit decrypted through MITM (verified against the generated CA), a
  real upstream forward, a 502 fall-through after `mock clear`, and the
  `network.*` evidence trail in `events.jsonl`. Runs in CI on the release binary.

- iOS: the SwiftUI accessibility bridge now descends into **unlabeled AX
  container elements** instead of filtering them out. Some hosting surfaces
  (notably a `TabView` page host — `TabHostingController`'s hosting view) wrap
  the whole page's elements in one container with no label, no identifier, and
  `isAccessibilityElement == false`; the previous one-level read dropped it —
  and with it the entire page — so tab-page content was plainly visible on
  screen yet absent from every snapshot, and `--test-id` selectors inside a tab
  could never resolve. A `NavigationView`'s `_UIHostingView` returns its
  elements flat, which is why every existing scenario worked and the gap went
  unnoticed. The walk is depth-capped and cycle-guarded. Found via a new
  four-item TabView scenario in `sample-app-ios` ("Tab bar"), which is now part
  of `scripts/e2e-ios.sh`: it asserts the four `UITabBar` items, that the
  SwiftUI page folds in as axElements, and that a HID tap on the Orders item
  flips `tabbar.status` to "Selected: orders". Also observed there (not a
  Reticle bug, worth knowing): the iOS 26 Liquid Glass `UITabBar` renders two
  stacked button layers, so each tab item appears twice at the same frame.

## 0.8.0 - 2026-07-20

- iOS: the capture proxy now supports **real devices**, not just simulators. A
  new `--proxy-bind` option (default `127.0.0.1`) lets the proxy bind the LAN
  (`0.0.0.0`) so a phone on the same Wi-Fi can reach it — previously the proxy
  was hardcoded to loopback, unreachable from a device. `serve --target ios
  --proxy-device` now prints device-appropriate routing: for a LAN bind it gives
  the Mac's LAN IP + port for the phone's Wi-Fi proxy and the CA-as-profile
  install/trust steps (`--proxy-install-ca` stays simulator-only — a device
  trusts the CA manually as a profile). Verified end-to-end on an iPhone 13 Pro
  Max / iOS 26: a Safari `https://example.com` fetch surfaced a decrypted
  `GET … 200` event targeted `ios:<ecid>`. Binding non-loopback is an explicit
  opt-in (it exposes the MITM proxy on the LAN for the run).

- iOS: the agent now engages the accessibility runtime at startup
  (`_AXSSetAutomationEnabled(true)` from `libAccessibility` — the flag XCUITest
  sets, no VoiceOver, fires no control), so SwiftUI `axElement`s carrying
  `.accessibilityIdentifier` surface on the **first** observation on a real
  device. Previously they built lazily and only after an accessibility action,
  so selector targeting silently missed on first use (the device e2e worked
  around it with a throwaway activation; that warm-up is now just a defensive
  poll). Verified on iPhone 13 Pro Max / iOS 26: the first `ui report` after
  launch lists all SwiftUI scenario buttons. (An earlier attempt used the
  non-existent `_AXSSetApplicationAccessibilityEnabled` setter symbol, hence the
  prior "flag insufficient" note — the working symbol is the automation pair.)

- iOS: hardened `scripts/e2e-ios-device.sh` and validated the full linked-agent
  real-device path on an iPhone 13 Pro Max (iOS 26): `status / ui report /
  ui compact / ui screenshot / act activate / mutate / debug logs` and the
  action-trace evidence package all confirmed over the USB tunnel. Script fixes
  surfaced by the run: auto-resolve the device via `idevice_id -l` (the hardware
  ECID is the one id that works for `xcodebuild -destination`, `devicectl`, and
  `iproxy` — the `devicectl` coredevice UUID does not); a lock-state precheck
  (a locked device rejects launch and suspends the app); wait for the agent to
  become reachable; and an action-trace assertion. Documented a real-device
  behavior: SwiftUI `axElement`s materialize only after an accessibility *action*
  (plain observation does not engage the tree), so the script does a throwaway
  activation to warm it before selector steps. Agent-side auto-engagement remains
  a follow-up (the `_AXSSetApplicationAccessibilityEnabled` flag alone did not
  suffice).

- iOS: `reticle serve --target ios` extends the host-side capture proxy
  (`network.*` events, HTTPS MITM, session mocks) to iOS simulators, within the
  same no-hook boundary as Android. Two host actions replace `adb`: the MITM CA
  is trusted in the booted simulator via `xcrun simctl keychain add-root-cert`
  (automatic with `--proxy-install-ca`, simulator-scoped), and — because a
  simulator/real device has no per-app proxy hook and rides the host network —
  proxy routing is **printed, not auto-applied**: `serve` emits the exact
  `networksetup` set/restore commands for the active service so the user runs and
  reverts the host-wide proxy explicitly (no risk of a killed daemon stranding
  the Mac on a dead port). Captured traffic is attributed `ios:<udid>` (the proxy
  target label is no longer hardcoded `android:`). Verified on iOS 26.3: a Safari
  `https://example.com` fetch surfaced a decrypted `GET … 200` event targeted
  `ios:<udid>`. This closes the iOS gap in the network-evidence lane and unblocks
  the security B-lane (B1/B2) on iOS.

- iOS: `act` (tap/swipe/drag/type/activate) now emits **action-trace evidence
  packages** — the iOS analogue of Android's traces, so an iOS action feeds the
  `reticle serve` timeline and web panel identically. `--trace-output <dir>` (or
  an active daemon session, which auto-traces) writes before/after snapshots +
  screenshots + a `trace.json` manifest whose compact diff records the observable
  change (e.g. `checkout.status: "Cart: 3 items" → "Paid!"` — honest proof the
  action landed). The manifest carries `platform: "ios"`, and the daemon now
  labels ingested traces `ios:<pkg>` (previously hardcoded `android:`). The diff
  is a field-for-field Swift port of `reticle-core`'s `ActionTraceDiff`, and
  `e2e-ios.sh` asserts the trace package and its diff. This closes the iOS gap in
  the evidence pipeline: iOS could drive actions but produced no evidence.

- iOS: fixed HID input (`act tap`/`swipe`/`drag`/`type`) silently doing nothing
  on the simulator. The previous path built the event from
  `IndigoHIDMessageForMouseNSEvent` and delivered it over a raw `SimDeviceIO`
  mach send right; on iOS 26.2/26.3 that *sends* cleanly but the synthesized
  touch never reaches native UIKit/SwiftUI controls (the worst failure — the
  agent believes it tapped). `CReticleSimHID` now builds a real `IOHIDEvent`
  digitizer parent + finger child, wraps it through
  `IndigoHIDMessageForTrackpadEventFromHIDEventRef`, patches the touch-target
  tag, and delivers via `SimDeviceLegacyHIDClient`
  (`-sendWithMessage:freeWhenDone:…`); keyboard uses
  `IndigoHIDMessageForHIDArbitrary`. Verified to land on native controls on iOS
  26.2 and 26.3. This also corrects the mistaken "HID needs iOS 26.3+" gate: HID
  is a capability, not a version cutoff — the host now guards on a capability
  probe (fails loudly only when the private SimulatorKit path can't initialize)
  and `e2e-ios.sh` runs HID steps on every runtime, asserting the tap actually
  lands (`checkout.status → "Paid!"`) rather than merely not erroring.

- iOS: web evidence hooks. The agent injects Playwright-style passthrough
  wrappers (console.*, window error / unhandledrejection, fetch / XHR timing)
  into every observed WKWebView; events buffer in an in-page ring (cap 200,
  drop-counted) and are drained into the agent log ring on every observation
  (`/report`, `/snapshot`, `/logs`), surfacing as `web_console` / `web_error` /
  `web_network` entries with structured metadata (url, method, status,
  durationMs). Pull-based like every Reticle observation: collection starts at
  the FIRST observation of a page; a document-start WKUserScript re-installs
  the hooks for later navigations. The sample fixture gained an evidence
  button and the e2e asserts console + fetch events end-to-end. Android port
  of the same script is a follow-up.

- WebView DOM walk (both platforms, shared script) now pierces **open shadow
  roots** and **same-origin iframes**, Playwright-style: pierced elements fold
  in as regular domNodes carrying a chained selector
  (`#shadow-host >>> #shadow-button`), with iframe content coordinates offset
  into page space. Cross-origin frames stay opaque. The sample's complex web
  fixture moved its shadow/iframe section above the fold so the e2e assertion
  doesn't sit on the viewport boundary.
- iOS: `act activate --css <chain>` performs in-process DOM activation — the
  agent resolves the selector chain in the live document (through shadow roots
  and same-origin iframes), runs a Playwright-style actionability check
  (attached / visible / enabled / receives pointer events, with honest failure
  reasons like `disabled` or `no_match`), and dispatches the full
  `pointerdown → mousedown → pointerup → mouseup → click` sequence. Needs no
  HID surface: this is the web tap path for real devices and for simulator
  runtimes with broken HID recognition. e2e asserts shadow/iframe chain
  activation plus an observable onclick side effect.

- iOS: multi-region decomposition reached parity with Android for UIKit text.
  The agent's new `RegionProbe` emits `span` regions from `.link` attribute runs
  (exact TextKit rects; UITextView lends its own stack, UILabel gets a rebuilt
  one), `a11yVirtual` regions from any view's child `accessibilityElements`
  (whole-view proxy elements filtered out), `colorSpan` regions for
  minority-colored runs, script-agnostic `textMarker` regions plus the
  `suspectedMultiRegion` flag for self-drawn bracketed/markdown rows, and a
  per-character `charGrid` for every UILabel/UITextView — so
  `act tap --region "Privacy"` resolves a phrase-level point on iOS (region rect
  first, char-grid substring fallback), same semantics as Android.
- iOS: `act activate` can now target SwiftUI content. axElement nodes resolve to
  their live accessibility element and fire `accessibilityActivate()` (e.g. a
  `NavigationLink` row navigates), `--region` narrows activation to an
  `a11yVirtual` sub-element, and text-range regions report an honest
  `no in-process activation surface` instead of tapping the whole view. Fixed
  SwiftUI `accessibilityIdentifier` being dropped for elements that respond to
  the selector without declaring `UIAccessibilityIdentification` (List rows),
  which made `--test-id scenario.*` unresolvable.
- iOS sample: restructured into the Android sample's scenario shape — a home
  list (Checkout / Agreement regions / SwiftUI boundary) with UIKit scenario
  screens mirroring the Android agreement cases (UITextView `.link` row,
  self-drawn bracketed-links label, plain-phrase label with non-default
  metrics, colorSpan row), plus a `RETICLE_SAMPLE_SCENARIO` launch-env hook so
  e2e runs can open a scenario without synthesizing navigation input.
- iOS: ported the read-only WebView DOM bridge to WKWebView. The view walk
  records web views on the main thread; the server thread then runs the shared
  DOM script (same payload as Android's `WebViewDomScript`) through
  `evaluateJavaScript` (750 ms timeout) and folds visible elements in as
  `domNode` children with `data-testid` selectors, `domCssSelector`, computed
  styles, and image metadata. `--css` selector resolution was added to the
  shared Swift `Render.findNode` (exact `domCssSelector` match, mirroring the
  Kotlin helper), so `ui node --css` and `act tap --css` now work on iOS. The
  sample gained the Android WebView scenario (same complex fixture) and the
  e2e asserts folded domNodes + CSS resolution.
- iOS: documented (docs/ios.md) that simulator HID taps do not trigger native
  UIKit/SwiftUI controls on the iOS 26.2 runtime (also reproduced with an
  independent implementation; the same tap DOES fire onclick inside WKWebView
  content, so delivery works and native gesture recognition is what rejects
  it); scripted flows should navigate via `act activate`. `scripts/e2e-ios.sh`
  now does, and asserts the agreement scenario's span/textMarker/colorSpan
  regions end-to-end.

- Proxy now **streams** upstream responses back to the client chunk-by-chunk
  instead of buffering the whole body first: identity bodies are forwarded under
  their original `Content-Length`, decoded/unknown-length bodies under
  `Transfer-Encoding: chunked`. A slow client back-pressures the upstream fetch
  (the transfer suspends until the client drains), and the stored response
  artifact is capped at the body limit while the full body still reaches the app
  (`responseBodyBytes` reports the true size, `responseBodyTruncated` flags the
  cap). Shared by the plaintext and HTTPS-MITM paths.
- Added a typed schema for proxy `network.*` payloads
  (`reticle-protocol/schema/network-event-payload.schema.json`) plus
  request/response/error golden fixtures. A Kotlin contract test validates the
  fixtures against it, and a Swift test pins the host emitter's field set to the
  same schema so the two ends can't drift.
- Network mock matching gained `match=regex` (validated at upsert, matched
  against both the request path and full URL), a `method=ANY` wildcard, and a
  query `"*"` presence predicate (key must exist with any value).
- Web panel: network cards can now be filtered by status class (2xx/3xx/4xx/5xx)
  and a free-text search over method/url/host/path/status/mock ids, composable
  with the existing mode filters; a new **Mock groups** view groups mocked
  requests under their rule (with hit counts) and the rest by host; and each card
  has a **copy as mock** chip that copies a ready-to-run `reticle mock set`
  command (including `--body-file` for the captured response). The panel stays
  display-only.

## 0.7.0 - 2026-07-14

- `act type` now focuses the target field first: given a targeting selector
  (`--test-id`, `--css`, `--point`, …) it taps the resolved field and waits a
  short settle before dispatching text, so input lands in that field instead of
  whatever happened to hold focus. Text is still inserted at the cursor.
- Added `Reticle.registerProbe(testId, metadata)`: a linked app can register a
  synthetic, addressable probe node for a spot with no convenient concrete view
  (canvas region, off-screen state).
- Added `schemaVersion` to the event envelope (currently `1`, required by the
  schema); legacy persisted session lines without it decode as version 1.
- Fixed `debug logcat` missing agent lines on busy devices: the tail cap was
  applied to the raw buffer before the tag filter, so Reticle lines could fall
  outside it and a linked agent looked unlinked. The dump is now tag-filtered
  first and bounded in code.
- Fixed mutation selector resolution and agent screenshots to consider all
  visible window roots topmost-first, so dialogs/overlays resolve and render
  correctly instead of the base activity winning.
- Hardened the agent's loopback HTTP server: route handler errors return a 500
  instead of dropping the connection; request bodies are capped at 4 MiB (413),
  header lines at 16 KiB, and a negative Content-Length is rejected (400).
- Hardened the helper RPC loop against type-mismatched request fields (a
  non-integer `id`, non-string `method`, or non-object `params` now yields a
  structured error instead of crashing the loop).
- Proxy correctness: a failed CONNECT now closes the client channel instead of
  leaking it, and `network.error` events preserve the real request method.
- Host resilience: SIGPIPE is ignored (a dead helper no longer kills the CLI),
  helper writes surface errors instead of trapping, and the final unterminated
  helper output line is read at EOF.
- Event store: id allocation and buffer mutation are serialized independently
  of file writes, and recovery sorts persisted events by id.
- Agent capture efficiency: AccessibilityNodeInfo instances are recycled and
  reflection lookups in the region/Compose probes go through a method cache.
- `adb` byte commands (screencap) return empty on a non-zero exit instead of
  passing through a truncated PNG.
- Raised host server bind-wait timeouts from 5s to 30s for slow CI machines.
- CI: Swift host tests now gate merges and releases (serialized suites to avoid
  a cross-suite server-start deadlock on core-scarce runners, with retries),
  SwiftPM dependency caching, a native-image serialization smoke test, and the
  release workflow runs the full test gates before publishing artifacts. Added
  a MITM/CONNECT proxy test suite.
- Slimmed the wire payload: `ReticleJson` now omits null and default-valued
  fields (`encodeDefaults=false`, `explicitNulls=false`, schema-required
  defaults pinned with `@EncodeDefault(ALWAYS)`), the agent serves HTTP
  responses with the compact (non-pretty) instance, and the `MetadataValue`
  `_type` discriminator uses short tags (`text`/`bool`/`int`/`real`) instead of
  fully-qualified Kotlin class names. Lossless; ~60% smaller snapshot responses.
- Fixed `SemanticTree.build` producing a dangling root and child refs: the tree
  now synthesizes a resolvable root, reparents kept nodes across dropped
  containers, and guarantees every node is reachable from the root.
- Unified the "targeting signal" test behind `Node.hasTargetingSignal()` so the
  semantic tree and compact observation can no longer disagree about which nodes
  are targetable.
- Hardened `input text` shell quoting to single-quote wrapping so typed text
  can no longer be interpreted by the device shell (`$(…)`, backticks).
- Made the daemon event store tolerate a corrupt or partially-written trailing
  JSONL line instead of failing to load the whole session.

Validation:

- reticle-core, Android helper, and Swift host tests.
- Plugin manifest/version-lockstep validation.
- GitHub CI for all pull requests.
- Real-device end-to-end pass on freshly installed builds: capture, tap/type
  (ASCII + CJK), mutate, screenshot, logcat, JDWP inject into the agent-free
  flavor, `serve` health, real-network proxy capture, and envelope
  `schemaVersion` — all verified on a physical device.

## 0.6.5 - 2026-07-03

- Added structured JSON result envelopes for host commands, including `--json`
  output on supported user-facing commands.
- Added selector-miss diagnostics with same-kind candidates from the current
  snapshot.
- Added `reticle ui outline`, short-lived `@N` aliases, and `reticle act
  --alias` for faster agent-driven targeting.
- Added a `reticle serve` helper broker so commands can reuse the daemon-hosted
  helper through `--use-daemon` or `RETICLE_USE_DAEMON=1`.
- Added runtime process advisories, persisted process-state, and matching
  serve-panel cues.
- Added repeated-item ordinal hints to UI outlines and alias cache entries.
- Added `reticle act batch` for ordered action sequences from a JSON file.

Validation:

- Swift host tests.
- Android helper tests.
- Plugin manifest/version-lockstep validation.
- GitHub CI for all optimization pull requests.
