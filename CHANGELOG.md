# Changelog

## Unreleased

- Sample apps + e2e: a new **system dialog** scenario on both platforms exercises
  the multi-window / presented-content walk that no other scenario covered.
  Android's `SystemDialogScenarioActivity` raises an `AlertDialog` (a separate
  `WindowManagerGlobal` root); the e2e asserts the dialog's own content
  (`alertTitle` / `message` / `button1` / `button2`) is captured AND the
  background trigger is reported `occluded-by` the dialog window — the
  window-vs-window occlusion path. iOS's `SystemDialogViewController` presents a
  `UIAlertController` *inside* the presenting window (not a separate `UIWindow`),
  so the e2e asserts the alert's title / message / actions are captured but
  deliberately makes no `occluded-by` assertion (iOS `UIWindow` nodes are captured
  as `.view`, so the window-occlusion path does not fire there). Both scenarios
  are app-owned dialogs — a true system-process permission prompt is out of reach
  for an in-process agent. Verified on an emulator + simulator; element content
  and frames confirmed pixel-accurate against screenshots.

- Network capture: a bridged engine start that the sync side abandons on timeout
  no longer leaks a bound port. `LoomCaptureLane.start()` and
  `startPhoneOnboarding()` bridge Loom's async engine to the daemon's synchronous
  lifecycle via a semaphore; on timeout they threw but left the `Task` running, so
  a start that completed *after* the timeout left an engine (or provisioning
  server) bound to a port with no owner to stop it. The bridging Task now claims
  its result under the lock and, when the sync side has already given up, stops the
  orphaned engine / provisioning server instead. (Cancelling the Task alone
  wouldn't help — Loom's actor calls don't observe cancellation, so an in-flight
  start still binds.)

- Android inject: the JDWP forward host port is now probed (`ServerSocket(0)`)
  instead of derived from the pid (`16000 + pid % 1000`). The derived port could
  collide with a stale forward left on it, an active runtime forward in the same
  range, or — for two pids congruent mod 1000 — a concurrent inject. A probed-free
  port can't already hold an adb forward (adb keeps forwarded ports bound), so all
  three modes are eliminated.

- iOS `act --verify` now works. The iOS path previously accepted `--verify` and
  silently dropped it, so an agent believed it had checked a post-condition it
  never checked. `IosHelperClient` now captures the watched node's state before the
  gesture, polls the snapshot after (up to `--verify-timeout`, default 2s), and
  emits the same `{selector, changed, note?, changes[]}` shape the host's
  `printVerify` renders — the iOS analogue of the Android helper's `HelperVerify`.
  The `--verify` token grammar (`#id`/`testId=`/`@id`/`resourceId=`/`css=`/`ref=`/
  bare ref/`true`) is shared-by-duplication with Android and now drift-guarded by
  `IosVerifyTokenTests`. Exercised end-to-end in `scripts/e2e-ios.sh` (login-status
  flip).

- RN `nativeID` selectors now resolve for `mutate` on Android. `SnapshotCapture`
  derived a node's `testId` as `testTag ?: nativeId ?: resourceId`, but
  `MutationEngine.findIn` only compared the keyless `testTag`, so a `testId` that
  came from an RN `nativeID` (a keyed tag) matched during capture but missed during
  device-side resolution — `mutate --test-id <nativeID>` silently found nothing.
  `findIn` now mirrors the capture derivation exactly.

- Network capture hardening (`LoomCaptureLane`): the capture lane no longer fails
  silently in ways that corrupt the evidence trail. (1) A transient
  `ruleStore.exportPackage()` error during a rule sync previously fell through to
  `setRules([])`, silently wiping every active rule in the engine — it now skips the
  sync and keeps the last-applied rules, logging a warning. (2) The rule-sync bridge
  gained the 30s timeout every other engine bridge already had, so a stalled engine
  can't deadlock the serial sync queue. (3) Body-store, CA-export, and `setRules`
  failures that were swallowed by `try?` now emit `warning: reticle capture: …` to
  stderr, so missing body/CA evidence is diagnosable instead of looking like a
  genuinely empty body or a misleading "file not found" downstream. (4) The
  `seen` flow-id set is now a bounded FIFO (cap 8192) instead of growing without
  limit over a long-lived daemon. (Session `network-bodies/` file count is still
  unbounded — it's coupled to event-ring eviction and left for a follow-up.)

- Network capture: **flow replay + diff** closes Loom's capture → modify → replay
  → diff loop. `POST /sessions/current/flows/{id}/replay` (CLI: `reticle replay
  flow <request-id>`) re-sends a captured flow through the engine's forwarder with
  optional overrides — `--method`/`--url`, `--set-headers`/`--remove-headers`, and
  `--body`/`--body-file`/`--clear-body` — then emits a `network.replay` event and
  returns the diff of the replayed response vs the original (status, body size, and
  header add/remove/change **by name only**, so a changed `Authorization` is named
  without logging the secret). The replayed flow's stream copy is suppressed in the
  capture lane so it shows once, as the replay event, with both bodies stored as
  artifacts. The payload schema gains optional `replayedFrom` + `diff` fields. Prior
  to this, Reticle captured and mocked but never exercised Loom's `replay` write
  action — the agent can now diff "same request without the auth header" as evidence.

- Network capture: the session mock store is now a general **traffic-rule**
  store, closing the gap where Reticle consumed only Loom's mock route while the
  engine's `RuleActions` offered far more. A rule's `actions` now carry one of
  four routes — `mock` (reply with a stored value, as before), `block` (fail the
  connection, for network-failure evidence), `mapRemote` (re-target the request
  at another origin, e.g. staging), or `passthrough` — plus orthogonal modifiers
  that compose with any route: `delayMs` (latency injection), request/response
  header rewrites, and request/response find/replace substitutions. These map
  1:1 onto Loom's `RuleActions` in `LoomCaptureLane.translate`. **Breaking
  (host-only surface; the agent never consumed it):** the `/sessions/current/mocks/*`
  routes are now `/sessions/current/rules/*` (values under `/rules/values`), the
  `reticle mock …` CLI is now `reticle rule …` with `--action`/`--map-to`/
  `--delay-ms`/`--set-*-headers`/`--remove-*-headers`/`--request-subs`/
  `--response-subs` flags, and session state persists to `rules.json` /
  `rule-values.json`. On captured evidence the `mocked`/`mockRuleId` payload
  fields are generalized to `ruleApplied`/`ruleId`/`ruleAction` (any route that
  acts is attributed, not just mock); `mockValueId` stays for the mock route. The
  Web panel's Mock filter/group/badge become the Rule filter/group/action badge,
  and "copy as mock" is now "copy as rule".

- Action traces: the on-disk `trace.json` manifest now carries a `platform`
  field ("android" / "ios") on both platforms. iOS already emitted it; the
  Android writer did not, so an Android trace was not self-describing and
  consumers could not tell the two apart from the manifest alone. The field is
  copied from the captured snapshot's platform and is optional/defaulted, so
  older manifests and direct callers stay wire-compatible.

- Tests: `scripts/e2e-android.sh` — an end-to-end smoke test for the Android
  agent, the analogue of `scripts/e2e-ios.sh` and the previously-missing
  coverage for the Android device-side runtime. It builds the agent + both
  sample flavors, installs them, and drives the full round trip against a
  device/emulator (linked launch, `ui report`/`compact`, selector tap with
  `--verify` + `--trace-output` + `replay gif`, ASCII/non-ASCII `type`,
  runtime `mutate`, agreement-region resolution, WebView DOM tap, the login
  keyboard-occlusion trap, `type --submit`, and the JDWP inject path on the
  `noagent` flavor) — every step asserting an observable side effect. It polls
  `status`/`compact` for readiness instead of fixed sleeps, so it rides out
  slow cold starts on a software-GPU emulator. Local/manual like the iOS e2e;
  not wired into CI (which has no attached device).

- One-shot commands now take a warm path by default: the first helper-backed
  command fork-execs a per-device `reticle helper-daemon` (a Unix-domain
  socket under `~/.reticle/helperd/`, carrying the helper's own JSONL
  envelope) and waits ≤5s for the socket; every later command reuses the
  resident helper over the socket instead of spawning a new helper process —
  measured ~20ms per command against ~90ms for a direct native-helper spawn,
  with the win growing on JVM helpers and multi-RPC commands. The daemon
  answers `helperd/info` / `helperd/shutdown` itself, restarts automatically
  when it is stale (CLI upgrade or helper rebuild, detected via version +
  helper mtime), exits after 600s idle (`RETICLE_HELPERD_IDLE` overrides),
  unlinks its socket on exit/SIGTERM, and exits when its helper child dies so
  the next command starts fresh. `--no-daemon` / `RETICLE_NO_DAEMON=1` opts
  out; any bring-up failure falls back to the direct per-command spawn, so the
  hot path is never a reliability regression. The `serve --helper-broker` +
  `--use-daemon` HTTP route is unchanged and takes precedence when requested.

- `act --verify` no longer false-negatives on `testId=`/`resourceId=` verify
  tokens. The token parser only understood the sigil spellings (`#testId`,
  `@resourceId`, `css=…`); anything else silently became a `ref` lookup that
  could never match, so `--verify 'testId=checkout.status'` reported
  "node not present after action" regardless of the actual UI — and the README
  and skill batch examples taught exactly that spelling. The parser now accepts
  `testId=`, `resourceId=`, and `ref=` alongside the sigils, and an
  *unrecognized* `key=` token fails loudly instead of degrading into a
  never-matching ref.

- iOS: `act type` with a targeting selector now taps that field first (then
  settles 200ms) before typing, matching Android — HID typing and clipboard
  paste both land in whatever holds focus, so `type --test-id foo` used to
  silently type into the wrong (or no) field unless the caller tapped first.
  The result reports `focusedVia`, and the action trace carries the focus
  point so replay evidence shows where the text went.

- Capture proxy: the upstream forwarder's total-transfer timeout is now
  `max(600s, configured upstream timeout)` instead of a hardcoded 600s that
  silently clamped any longer `--upstream-timeout`.

- Capture proxy: a request body is now capped at 64 MiB of in-memory buffering
  by default (`--proxy-max-request-body-mb` on `reticle serve`). The upstream
  forward needs the whole body in memory today, so an unbounded upload could
  balloon the daemon; past the cap the proxy emits a `network.error` event,
  answers `413`, and closes the connection. Applies to both the plaintext and
  MITM paths. This is a safety valve, not a tight bound — the default clears
  ordinary photo/video uploads.

- Swift host: the `network.*` payload, event-envelope, and snapshot schemas are
  now validated at the value level against `reticle-protocol/schema/*.json`,
  matching the Kotlin contract test. The Swift side previously compared only
  field-name sets, so a type / enum / nesting drift (e.g. a MetadataValue
  discriminator or a number-vs-integer slip) could pass unnoticed. A small
  test-only draft-2020-12 validator (no third-party dependency) now checks the
  Swift-emitted snapshot, the shared iOS golden fixture, and the network/event
  golden fixtures; its own self-tests prove it rejects the drift it guards
  against.

## 0.9.3 - 2026-07-22

- iOS real-device enablement (docs + tooling, no runtime behavior change):
  - **CocoaPods linked path.** Ship `reticle-swift/ReticleProtocol.podspec` and
    `reticle-agent/ios/ReticleKit.podspec` so a CocoaPods app (e.g. a KMP iOS
    app) can link the agent Debug-only and call `Reticle.start()` — the
    recommended way to drive a real device, alongside the existing SwiftPM path.
  - **Debug-build injection.** `scripts/inject-ios-device.sh` (+
    `scripts/macho_add_load.py`, lief-based) inject the agent into an
    already-built, dev-signed debug `.app` with no source change: build
    `ReticleInjection.framework` for device, embed it, add an `LC_LOAD_DYLIB`,
    re-sign framework + bundle with the app's own identity, reinstall, verify
    over the USB tunnel. Documents what does NOT work on-device
    (`DYLD_INSERT_LIBRARIES` is stripped by the launch path; lldb `dlopen` is
    blocked on iOS 26) and that production/App-Store apps cannot be injected at
    all. Prefer the linked path; injection is for debug builds you can't edit.
  - `docs/ios.md` and the plugin skill document both real-device routes.

## 0.9.2 - 2026-07-22

- `act type --submit` presses the keyboard's action key after the text lands,
  collapsing the OTP-style `type` → `hide-keyboard` → `tap submit` three-step
  into one command. On Android the agent performs the focused field's IME
  editor action in-process (`POST /editor-action` → `EditorActionResult`):
  `TextView.onEditorAction()` drives the app's `OnEditorActionListener` — the
  exact hook React Native's `onSubmitEditing` listens on — where a host-side
  `KEYCODE_ENTER` inserts a newline into multiline fields and is dropped by
  some IMEs; fields that never declared an action are treated as Done. Because
  a real IME dismisses itself after a terminal action, the agent reproduces
  that: Done/Go/Search/Send also hide the keyboard, Next/Previous keep it up.
  Falls back to `KEYCODE_ENTER` when the agent is unreachable. On the iOS
  simulator `--submit` sends a HID Return (the bridge already mapped `\n` to
  the Return usage). Works in `act batch` steps as `"submit": true`. Verified
  end-to-end on a real Android device (ColorOS, API 35) and an iOS 26.3
  simulator: one command types the code, fires the app's submit listener, and
  leaves the keyboard dismissed.

- Android: React Native's `nativeID` is now a first-class `testId` source.
  RN stores `nativeID` as a *keyed* view tag (`setTag(R.id.view_tag_native_id,
  …)`), invisible to the keyless `view.tag` read that fills `testId` — so an
  RN screen with `nativeID` props (and no resource-ids) was untargetable by
  `--test-id` and agents fell back to per-restart dynamic refs. The capture
  now resolves RN's tag id by name at runtime (no RN dependency) and fills
  `testId` from: Compose/classic testTag → RN `nativeID` → resource-id entry
  name. (RN's `testID` already worked — it writes the keyless tag.)

- `act --alias @N` now re-resolves the cached outline entry against the live
  tree before acting, instead of trusting the coordinates the outline cached.
  A keyboard appearing or a relayout between `ui outline` and `act` used to
  land the tap on stale coordinates *silently* — worse than a stale `ref`,
  which at least fails loudly. Matching is by the entry's stable selector
  (testId / resourceId / css) first, then label+role, preferring the node
  nearest the cached frame when several match (repeated list rows); the
  cached frame remains the fallback when the runtime is unreachable, and the
  result's `source` says which path ran (`outline:@N->live` vs
  `outline:@N (cached frame)`).

- Docs: the `act batch` examples now show what was always true — step keys
  are the protocol field names, so `resourceId`, `ref`, `point`, `alias`, and
  `region` all work in steps, not just `testId`/`css` (README, skill, and
  helper-rpc.md all updated; this cost a real user their whole steps.json
  workflow). `app inject` success output now points out that debug builds
  linking the agent AAR skip inject entirely, and the skill documents the
  `serve --helper-broker` daemon path and the alias live-re-resolve semantics.

- Sample apps (both platforms): the login scenario's code field now also
  submits on the keyboard's Done/Return key (the common OTP pattern), giving
  `act type --submit` a listener to land on. The bottom submit button stays —
  it is the occlusion scenario the hide-keyboard E2E drives.

## 0.9.1 - 2026-07-22

- Android: the system keyboard (IME) is now observable and dismissible. The
  IME is another process's window — it never appears in the captured node
  tree, so a login button it covered still read as `tappable` and agents
  tapped straight into the keys (a real stuck login flow: type the SMS code,
  keyboard stays up, submit button underneath it). Snapshots now carry
  `screen.keyboard` (`visible` + screen-coordinate `frame`), probed in-process
  from window insets (`WindowInsets.Type.ime()` on API 30+, visible-frame
  heuristic before that); the agent answers `GET /keyboard` and
  `POST /keyboard/hide` (InputMethodManager against every attached window
  token, then re-probe so the caller gets the settled state); and
  `reticle act hide-keyboard` drives it from the CLI, falling back to
  `KEYCODE_ESCAPE` when the agent is unreachable — unlike BACK, ESC doesn't
  navigate back when the keyboard is already gone. `act type` results now
  include `keyboardVisible` when the runtime is reachable.

- iOS: the same keyboard surface, implemented in-process in `ReticleKit`. A
  `KeyboardMonitor` caches the keyboard notification stream (the one exact
  public signal — the keyboard's own windows attach on first text focus and
  never detach, so window presence proves nothing) and falls back to scanning
  for a text-input first responder when injected mid-keyboard. `GET /keyboard`
  / `POST /keyboard/hide` (resignFirstResponder via the responder chain, then
  re-probe) mirror Android; `reticle --target ios act hide-keyboard` works on
  simulators and real devices alike since it needs no HID surface, and iOS
  `act type` also reports `keyboardVisible`. Verified end-to-end in
  `scripts/e2e-ios.sh` (see below). Simulator caveat baked into the script:
  with "Connect Hardware Keyboard" on, iOS never shows the software keyboard —
  the script now disables it up front.

- Sample apps (both platforms): a new "Login keyboard trap" scenario — code
  field on top, submit button pinned to the bottom, keyboard avoidance
  deliberately defeated (`adjustNothing` on Android, `.ignoresSafeArea(
  .keyboard)` on iOS) — reproducing the real stuck-login layout. The iOS e2e
  drives it end to end: type → `keyboardVisible=true` → compact marks
  `login.submitButton occluded-by:keyboard` → `act hide-keyboard` →
  `keyboard: hidden` → submit succeeds. The same flow was verified by hand on
  a real Android device (ColorOS, API 35) — including the probe fix it forced:
  IME insets only dispatch to the focused window, so the agent probes every
  attached window and lets any that sees the keyboard win.

- Compact view: items whose tap point something else sits on top of are marked
  `occluded-by:<what>` — generically, not keyboard-specifically: a higher
  z-order window (dialog/popup over a background page) marks the items it
  covers with its window ref, and the visible IME marks the items under it
  with `occluded-by:keyboard`. `ui compact` also leads with a
  `keyboard: visible/hidden` header line (with a dismiss hint) whenever the
  platform probed the IME. Protocol: `ScreenInfo.keyboard` (`KeyboardInfo`)
  and `CompactItem.occludedBy` added to the schema, the Kotlin model, and the
  Swift `ReticleProtocol` mirror — all optional, wire-compatible both ways.

## 0.9.0 - 2026-07-21

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
