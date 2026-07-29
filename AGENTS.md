# Reticle Agent Guide

This repository is a Gradle/Kotlin project for Reticle, an Android runtime
inspection, diagnostic, and action harness — it inspects the app that is
actually running, resolves precise selectors and tap regions, and drives real
input through adb.

Use this file as a map. Deeper architecture lives in `docs/architecture.md`, and
what Reticle structurally cannot reach in `docs/boundaries.md`.
`docs/architecture-map/` holds the same shape in two consumable forms: an
interactive page (`index.html`) and `map.json` (`{nodes, edges, flows:[{steps}]}`)
for an agent that wants the module graph and the named flows without parsing prose.
It is generated from the prose docs — edit those first, then the map. The map
lives in two copies (the JSON and a verbatim block inside the page);
`scripts/validate_architecture_map.py --fix` resyncs them and the bare script is
a CI gate, so they cannot drift again. `docs/roadmap.md` and its `zh-CN` twin are
checked the same way by `scripts/validate_translations.py` — heading skeletons
only, since prose cannot be diffed across languages.

## Current Shape

- `reticle-core`: pure JVM snapshot models, semantic tree models, compact
  observations, wire protocol, selectors, and the text projections themselves
  (`Render` — `compact` / `tree` / `semantics` / `regions`, beside
  `StyleObservation.render`). No Android dependency. Shared by the CLI and the
  in-app agent. One implementation of `reticle-protocol`; the Swift
  `ReticleProtocol` is the parallel one. **A projection's formatting belongs here,
  not in the helper**: a derivation shared while its rendering is not has only half
  a contract, which is how `compact` drifted before
  `reticle-protocol/fixtures/snapshot-render.cases.json` pinned both sides.
- `reticle-swift` (`ReticleProtocol`): SwiftPM library — the Swift implementation
  of `reticle-protocol` (Codable models with omit-defaults JSON, `SemanticTree` /
  `CompactObservation` derivations, `PortMap`, and `Render` — the twin of
  `dev.reticle.core.Render`, pinned against it by
  `reticle-protocol/fixtures/snapshot-render.cases.json`). Depended on by both the
  iOS agent and the Swift host so the protocol is never re-ported. Outside the
  Gradle build.
- `reticle-agent/android` (`:reticle-agent:android`): Android library (AAR).
  In-process loopback HTTP server, view-tree + Compose-semantics capture,
  allowlisted runtime mutation, in-process screenshot, app-authored log/metadata
  bridge, and an auto-start `ContentProvider`. `reticle-agent/` is a grouping
  directory (no build.gradle); per-platform agents are its children. Its unit
  tests run under Robolectric in **NATIVE graphics mode**
  (`src/test/resources/robolectric.properties`): the default mode fakes text
  metrics, so a `RegionProbe` suite written against it would assert the fake and
  pass while the real `android.text.Layout` produced different rects.
- `reticle-agent/ios` (`ReticleKit` + `ReticleInjection` +
  `ReticleInjectionBootstrap`): SwiftPM package — the in-process iOS agent. Same
  shape as the Android agent: loopback HTTP server, UIKit view-tree capture, a
  SwiftUI bridge that emits `axElement` nodes only from natively-exposed
  accessibility elements (never private SwiftUI internals) — including
  `SwiftUITextRegions`, which recovers the links inside ONE markdown `Text` as
  `span` sub-regions from its `accessibilityAttributedLabel` (the Compose-links
  twin) — allowlist mutation,
  in-process screenshot, `Reticle` facade, and dual auto-start (a DYLD-constructor
  bootstrap for injection, plus a linked `Reticle.start()`). Emits `platform="ios"`
  protocol JSON. Built by SwiftPM, invisible to Gradle. Its unit tests
  (`Tests/ReticleKitTests`, run by `scripts/test-ios-agent.sh`) need XCTest on a
  simulator rather than `swift test` — UIKit-only code, and real views/TextKit are
  what the capture logic is made of.
- `reticle-helper`: the Android host layer (Kotlin) — adb + JDWP injector + input
  + loopback client. **Not a user-facing CLI**: its only entry points are
  `helper` (a long-lived JSONL RPC server, `Helper.kt`), `version`, and `help`.
  It ships as the no-JDK native `reticle-helper` (GraalVM native-image, built by
  `:reticle-helper:nativeHelper`) that the Swift host drives. The runtime probe,
  injection (`Injector.kt` + `Jdwp.kt`, a dependency-free JDWP client — payload
  dex into a debuggable app, no AAR/repackage/root) and all device I/O live here.
  Selector *resolution* does not: it is fixture-pinned across both languages, so it
  sits in `reticle-core` beside its Swift twin (`SelectorResolution`), and the helper
  keeps only the host-side diagnostics for a miss.

  The three platform seams (device control, injection,
  input) sit behind a `dev.reticle.cli.platform` SPI; the Android implementation
  (`Adb`/`Injector`/`InputBackend`/`Jdwp`) is under `platform/android`, selected
  via `--target` (default `android`). Adding a platform = a new `platform/<os>`
  implementation, no dispatcher changes. RPC contract:
  `reticle-protocol/helper-rpc.md`.
- `reticle-host`: the **Swift host CLI** (`reticle-host/`, SwiftPM, macOS 14+
  arm64,
  outside the Gradle build). The user-facing `reticle`; owns no device code —
  device commands are RPC calls to the native helper it spawns. It also contains
  the `reticle serve` daemon: a Hummingbird 2.25.0 localhost REST/SSE session
  event bus with append-only `~/.reticle/sessions/<session>/events.jsonl`, the
  read-only web panel, best-effort action-trace ingestion from `act
  --trace-output`, and the Loom-backed network capture lane (traffic rules + flow
  replay).
  Command surface: `doctor`/`devices`/`status`/`app launch|inject`/`act`/`mutate`/
  `debug`/`ui`/`rule`/`replay`/`serve`/`version`.
  Internally three stacked SwiftPM library targets: `ReticleHostShared`
  (dependency-free `JSONValue`/event models/`HelperError`) ← `ReticleNetworkLane`
  (the capture lane — runs Loom's `ProxyEngine`, normalizes flows, owns the
  traffic-rule store + replay, reaching the session store only through the
  `NetworkEventSink` protocol; transport/MITM/CA are Loom's, so the lane carries no
  SwiftNIO of its own) ← `ReticleHostCore` (daemon, CLI, panel, host code), plus
  the `ReticleHost` executable. Put new capture/rule code in the lane, not Core;
  its end-to-end path is guarded by `scripts/e2e-proxy.sh`.
- `sample-app`: demo app that links the agent and proves the round trip. Has two
  flavors: `linked` (depends on the agent) and `noagent` (no agent, no runtime
  classes, declares `INTERNET`) — the honest test target for `app inject`.

## Claude Code plugin packaging

The repo is ALSO a Claude Code plugin (and its own single-plugin marketplace),
so it installs over the network with `/plugin marketplace add KQAR/Reticle` then
`/plugin install reticle@reticle`.

- `.claude-plugin/plugin.json` — plugin manifest (`name: reticle`).
- `.claude-plugin/marketplace.json` — marketplace catalog; the plugin entry uses
  `source: "./"` (the repo root is the plugin).
- `.cursor-plugin/plugin.json` + `.cursor-plugin/marketplace.json` — the Cursor
  mirror of the two above. Same `name`/`version`/`source: "./"`; the plugin
  manifest adds `displayName` and relative dir pointers (`skills`, `commands`).
  Both editors share ONE `skills/` and `commands/` — never fork the content; only
  the manifests differ. `claude plugin validate .` covers the Claude pair;
  `scripts/validate_plugin.py` covers BOTH pairs.
- `bin/reticle` — launcher added to the Bash PATH when the plugin is enabled.
  `reticle` IS the Swift host; the launcher resolves/execs `reticle-host` with the
  native `reticle-helper` beside it. Default path ALWAYS uses the prebuilt release
  (SHA256-verified, cached under `~/.reticle/cli` or downloaded from Releases) and
  never silently builds from source; if the download fails it hard-stops with
  guidance. Order: `$RETICLE_HOST` → `$RETICLE_HOME/bin` → `RETICLE_FROM_SOURCE=1`
  (opt-in source build: Swift host + native helper) → prebuilt release.
  `release.yml` publishes `reticle-macos-arm64.zip` (host + native helper) + the
  agent AAR on a `v*` tag, from a macOS arm64 runner. No JDK to run. macOS 14+
  arm64 only.
- `skills/reticle/SKILL.md` — model-invoked skill describing the workflow.
- `commands/report.md`, `commands/tap.md`, `commands/inject.md` — slash commands
  (`/reticle:report`, `/reticle:tap`, `/reticle:inject`). Thin wrappers: each one
  defers to the skill for the workflow instead of restating it, so the two cannot
  drift apart.

Validate after changing any manifest/skill/command: `claude plugin validate .`
locally. CI runs a dependency-free check instead
(`python3 scripts/validate_plugin.py`): well-formed JSON + required fields +
in-repo source paths exist, across BOTH the Claude and Cursor manifests, plus a
**version-lockstep** check — every manifest version, the `bin/reticle` launcher
default, and the `RETICLE_VERSION`/`VERSION` constants must all agree. When you
bump the version, change all of them together (the validator fails loudly on
skew). Only the manifests live under `.claude-plugin/` and `.cursor-plugin/`;
`skills/`, `commands/`, `bin/` stay at the repo (plugin) root and are shared.

## Architecture Rules

- The agent observes app state. It is not the place where input events are
  synthesized — real input comes from the host via `adb shell input`.
- Use the view tree for UI/layout/style validation. Use the semantic tree
  first for movement and input; selector actions fall back to view frames only
  when no semantic match exists.
- Reticle does not synthesize a Compose view tree. Compose elements are valid
  movement/input targets only when exposed through the SemanticsNode tree
  (`Modifier.testTag`, contentDescription). Never invent selectors from private
  Compose internals. The `scenario.compose` sample screen is the end-to-end
  coverage for this path (tagged tap, `type` into a composable `TextField`, a
  `Dialog`'s own window/semantics owner, and an `AndroidView` interop child).
  Links inside a Compose `Text` are sub-regions of that one node, recovered by
  `ComposeTextRegions` from the semantics config (`Text`'s link annotations +
  the `GetTextLayoutResult` action's geometry) — reflectively, like the rest of
  the Compose path.
- The CLI exposes `tap`, `swipe`, `drag`, `scroll-to`, and `type`. `scroll-to`
  drags a scrollable container until a selector resolves inside it and confirms
  the position settled before reporting it — the only way to reach a row a
  recycling list has not bound. `tap --settle` opts into that same stabilize step
  for a tap, for a target still sliding in (a popup row's rect goes stale between
  resolve and dispatch); it watches the resolved POSITION only, so a view animating
  in place with a transform reports settled while not yet hit-testable. `pinch`
  keeps the API shape but is not implemented (needs `sendevent` multi-touch).
- `act wait` is the only `act` gesture that dispatches no input — it polls until a
  stated predicate holds. It exists because nothing else can express "act, then a
  NEW screen appears": `--verify` can only watch a node that ALREADY resolves, and
  `--settle` only watches whether a point stopped moving. Predicates: `--for
  <selector>` (appear), `+ --gone`, `+ --text <substring>`, or `--idle` for the
  screen itself going quiet. It takes neither `--point` (a coordinate always
  "resolves") nor `--alias` (an alias describes the screen a wait exists to watch
  change), and refuses both by name.
  - **The success test is resolution through the act's own path, never
    `isVisible`.** An earlier `wait --for appears` proposal was dropped over that
    proxy (see the comments on `HelperScrollTo` and `settleInputTarget`); the
    guarantee this one carries instead is that a `resolved` wait means the very
    next `act` resolves the same way. Visibility and occlusion are reported as
    caveats, not as the verdict.
  - **The outcome is three-state, and the third state is the point:** `resolved` /
    `absent` (a miss nothing prevented seeing) / `unknowable` (a miss that could
    not have been seen — lost window focus, an unbound list row, an unreadable
    DOM, a screen that never settled, an ambiguous label). Collapsing `unknowable`
    into `absent` is how an observer lies: an agent reads `absent` as "the feature
    is broken". `WaitVerdict.classify` in `reticle-core` (mirrored in
    `ReticleProtocol`) decides this, pinned for BOTH platforms by
    `reticle-protocol/fixtures/wait-classification.cases.json` — add a branch
    there or it ships unpinned on one side.
  - The outcome is a FIELD; `--json` stays `{"ok":true}` on a timeout, because a
    predicate that did not come true is an observation, not a tool failure. Exit
    codes are an opt-in lossy projection for shell/CI (`--strict`: 3 = absent,
    4 = unknowable, kept distinct on purpose).
- Keep full snapshots on disk. Send compact observations to agents by default,
  then query or inspect specific refs on demand.
- Runtime mutation is allowlisted (`alpha`, `visibility`, `text`,
  `backgroundColor`, `enabled`). Compose nodes are intentionally not mutable;
  drive declarative UI through app-owned state.

## Toolchain

Versions and how to install them: README.md -> **Toolchain**. Only the parts a
build here depends on and the README does not spell out:

- The build **pins the Gradle daemon to JDK 17** via
  `gradle/gradle-daemon-jvm.properties` (`toolchainVersion=17`), so the wrapper
  auto-selects a locally-installed 17 even when the default `java` is newer — no
  `JAVA_HOME` needed. (A too-new default like JDK 26 otherwise crashes the daemon
  and AGP 8.7.) Fallback if none is detected:
  `JAVA_HOME=$(/usr/libexec/java_home -v 17)`.
- `native-image` for `:reticle-helper:nativeHelper` is located via `$GRAALVM_HOME`
  or `native-image` on PATH.
- Android SDK expected at `~/Library/Android/sdk` (compileSdk 35, build-tools
  present).

## Verification

Build everything (the daemon auto-pins to JDK 17 — see Toolchain):

```bash
./gradlew assemble
```

The whole runtime round trip below is also scripted as an automated smoke test —
the Android analogue of `scripts/e2e-ios.sh`:

```bash
swift build --package-path reticle-host        # ReticleHost
./gradlew :reticle-helper:nativeHelper          # native reticle-helper
scripts/e2e-android.sh [<serial>]               # full device/emulator round trip
```

It builds the agent + both sample flavors, installs them, and drives every
scenario (checkout tap + `--verify` + `--trace-output`, ASCII/non-ASCII type,
mutation, agreement regions, the system permission prompt (out-of-process window ->
`window: UNFOCUSED`), the web JS dialog (alert() blocking the page's JS
thread -> `dom:unavailable`), the popup windows (PopupWindow / Spinner dropdown /
PopupMenu + `--label`), the wheel picker (a `NumberPicker`'s unselected values are
canvas paint, not nodes — the one scenario where the two platforms deliberately
report different amounts, since a `UIPickerView`'s rows ARE nodes),
the toasts screen (a system-drawn text toast is in no tree and no in-process
screenshot — recovered from the Toast Queue — next to an app-drawn one and a
`WindowManager` overlay, which are ordinary nodes),
the long list (recycling boundary + scroll evidence), the reformatting input
fields (`type` reads the field back: `textLanded=reformatted` for an app's own
formatting, a partial burst detected and re-sent over the clipboard, and
`--type-delay`'s paced path), the
Compose semantics screen, the canvas control
(virtual a11y sub-nodes under both id conventions + a touch-delegate rect),
WebView DOM, same-origin iframe geometry (chained selector + a coordinate tap into
the frame), the login keyboard trap, the system
dialog (AlertDialog window recognition + occlusion), the native Lottie dialog,
the web Lottie modal, the web-component (shadow DOM) modal, the Lottie-only
dialog (recovering title/message/buttons baked into one Lottie via the Lottie
bridge), and the JDWP inject path on `noagent`), asserting an observable side
effect at each step. It
polls `status`/`compact` for readiness rather than fixed sleeps, so it tolerates
slow cold starts on a software-GPU emulator. On such an emulator, disable the
Google apps that ANR under load first (their dialogs are a *separate* window that
steals taps and never appears in the node tree). It is a manual/local check like
the iOS e2e — not wired into CI, which has no attached device.

The manual steps, for reference:

Prove the runtime round trip on a booted device/emulator:

```bash
./gradlew :sample-app:assembleDebug
adb install -r -t sample-app/build/outputs/apk/linked/debug/sample-app-linked-debug.apk

# `bin/reticle` is the Swift host launcher; RETICLE_FROM_SOURCE=1 builds the host
# (swift) + native helper (gradle native-image) from source. Needs Swift + a GraalVM.
export RETICLE_FROM_SOURCE=1 RETICLE_NO_REDIRECT=1
export RETICLE_ADB="$ANDROID_HOME/platform-tools/adb"
CLI="bin/reticle"

$CLI app launch  --package dev.reticle.sample
$CLI ui report   --package dev.reticle.sample --output /tmp/reticle-report
$CLI ui compact  /tmp/reticle-report/snapshot.json
$CLI act tap     --package dev.reticle.sample --test-id scenario.checkout
$CLI ui report   --package dev.reticle.sample --output /tmp/reticle-report
$CLI ui node     /tmp/reticle-report/snapshot.json --test-id checkout.payButton
$CLI act tap     --package dev.reticle.sample --test-id checkout.payButton
$CLI act tap     --package dev.reticle.sample --test-id scenario.webview
$CLI ui report   --package dev.reticle.sample --output /tmp/reticle-webview
$CLI ui node     /tmp/reticle-webview/snapshot.json --css '#style-target'
$CLI act tap     --package dev.reticle.sample --css '#style-target' \
                 --verify 'css=#style-target' --trace-output /tmp/reticle-traces
$CLI debug logs  --package dev.reticle.sample
$CLI mutate      --package dev.reticle.sample --test-id checkout.status \
                 --property text --value "Cart: 3 items"

# The keyboard trap (scenario.login): typing leaves the IME covering the
# bottom-pinned submit button. Verified 2026-07-21 on a real device (ColorOS,
# API 35): type reports keyboardVisible=1, compact leads with
# `keyboard: visible [rect]` and marks `login.submitButton … occluded-by:keyboard`,
# hide-keyboard reports via=agent imm wasVisible=1, and the follow-up tap flips
# login.status to "Logged in: 123456".
$CLI act tap          --package dev.reticle.sample --test-id scenario.login
$CLI act type         --package dev.reticle.sample --test-id login.codeField --text "123456"
$CLI ui compact       --live --package dev.reticle.sample
$CLI act hide-keyboard --package dev.reticle.sample
$CLI act tap          --package dev.reticle.sample --test-id login.submitButton
```

Expected: the home screen lists scenario rows, `scenario.checkout` opens the
checkout screen, the pay-button tap resolves via `semantic:testId`, the status
text flips to "Paid!" after the tap, the WebView DOM node resolves via
`dom:css`, `--verify 'css=#style-target'` reports DOM text/style changes, a trace
directory appears with `trace.json` plus before/after snapshots (and screenshots
when the agent screenshot path is available), and the logs include
`checkout_visible` / `checkout_paid`.

Prove the **unlinked** (JDWP injection) path on the `noagent` flavor:

```bash
JAVA_HOME=$(/usr/libexec/java_home -v 17) ./gradlew \
  :reticle-agent:android:dexPayload :sample-app:assembleNoagentDebug
adb install -r -t sample-app/build/outputs/apk/noagent/debug/sample-app-noagent-debug.apk
adb shell monkey -p dev.reticle.sample.noagent -c android.intent.category.LAUNCHER 1

export RETICLE_FROM_SOURCE=1 RETICLE_NO_REDIRECT=1
CLI="bin/reticle"
$CLI app inject --package dev.reticle.sample.noagent   # loads the dex over JDWP, starts the runtime
$CLI ui report  --package dev.reticle.sample.noagent --output /tmp/reticle-noagent
$CLI act tap    --package dev.reticle.sample.noagent --test-id scenario.webview
$CLI ui report  --package dev.reticle.sample.noagent --output /tmp/reticle-noagent-webview
$CLI ui node    /tmp/reticle-noagent-webview/snapshot.json --css '#style-target'
```

Expected: `app inject` prints `runtime live: … port=…`, and `ui report` returns a
non-empty tree (`#checkout.payButton`, the agreement rows), and the injected
runtime can also expose WebView DOM nodes such as `#style-target` — proving the
runtime is serving inside an app that carries none of `dev.reticle.agent.*`. Set
`RETICLE_JDWP_DEBUG=1` for a step trace if it stalls. The dex must be read-only
on-device (the CLI does this) or ART's W^X policy rejects it.

## Known Boundary

The complete list lives in `docs/boundaries.md` (**Honest boundaries**): every
structurally unreachable case next to the evidence emitted for it and the scenario
that pins it. Keep it current — a boundary discovered and not written down there is
one a future contributor re-investigates from scratch. The entries below are the
operational notes that don't fit that table.

- `app launch` uses `monkey ... LAUNCHER` (retried once on a transient adb-shell
  timeout); the agent auto-starts via its `ContentProvider`, so no special launch
  env is needed for linked apps.
- The loopback port is derived per-app from the `applicationId` via
  `PortMap.derivePort` in `reticle-core` (shared verbatim by agent and CLI), so
  multiple linked apps don't collide on one fixed port. `RETICLE_PORT` (app) +
  `--port` (CLI) override it. Changing the hash desyncs both sides — the pinned
  vectors in `PortMapTest` guard against that.
- Device selection: a global `--serial <id>` scopes every command to one device
  (the host injects it into every RPC call via `HelperClient`); absent that,
  `Adb` falls back to `$ANDROID_SERIAL`. With multiple devices and neither set,
  `deviceState()` throws a `DeviceError` naming the candidates rather than
  guessing — `doctor`/`devices` still list them all. See `AdbDeviceSelectionTest`.
- `WebViewBridge` is typed on `android.webkit.WebView`, so a third-party kernel
  (X5/TBS, UC) has no DOM at any level. Deliberately NOT adapted reflectively — it
  could not be verified without a real kernel sample. Instead the capture marks such
  a view `dom:unsupported-kernel` (+ `custom.domKernel`) and a `--css` miss explains
  it; `scenario.foreignKernel` covers the shape with a self-drawn stand-in beside a
  real WebView.
- The two screenshot blind spots are exact complements, and both are now
  **labelled** rather than left as a blank rect (measured by
  `scenario.screenshotDegrade`): a `SurfaceView`'s own surface is missing from the
  in-process capture (transparent hole) but present in `adb exec-out screencap`, so
  its node carries `pixels:unavailable`; a `FLAG_SECURE` window blanks the
  device-level capture while the in-process one is fine, so its window node carries
  `screencap:blank`. `reticle ui screenshot` prints a `degraded:` line for whichever
  applies to the picture it just wrote. On iOS the same `pixels:unavailable` marks
  the keyboard's host window, which will not render into an in-process context.
- Injection into apps without the AAR: `reticle app inject` over JDWP for any
  **debuggable** app (no repackage, no root — works on locked `user` builds where
  `wrap.sh` is blocked); the payload dex is built by `:reticle-agent:android:dexPayload`
  and resolved via the `reticle.payloadDex` sysprop / `$RETICLE_PAYLOAD_DEX` →
  gradle build output → `<cli>/lib/` (the helper RPC sets the sysprop explicitly).
  Non-debuggable release builds still need Frida/root. See `docs/architecture.md`
  for the JDWP sequence and its on-device constraints.
