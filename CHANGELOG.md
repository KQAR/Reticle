# Changelog

## Unreleased

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
