# Reticle

**English** | [简体中文](README.zh-CN.md)

Reticle helps AI coding agents build and verify native app interfaces on
**Android and iOS** by inspecting the app that is actually running — not just the
source code or a screenshot.

Reticle's job is to *locate and measure* what's on screen: resolve stable
selectors and precise coordinates from the live view / accessibility /
Compose-semantics / SwiftUI tree so an agent can act on the right element with
confidence. One CLI, one wire protocol, one command surface: `--target ios`
selects the platform (default `android`).

Tools like `adb`, Espresso, UiAutomator and XCUITest can build, launch, or drive
an app. Reticle adds the runtime UI layer: structured evidence from the app that
is actually running, so agents can inspect, probe, and verify native interface
work.

## Why use Reticle

- **Less guessing from screenshots.** Agents inspect the running app through
  native view trees, accessibility/semantics metadata, screenshots, and logs.
- **Fewer missed UI issues.** Reticle checks layout, hit testing, and design
  drift against the live interface.
- **Precise targeting inside one View.** Agreement rows, "highlighted = link"
  text, and self-drawn controls often pack several tap targets into a single
  node. Reticle resolves them down to the specific phrase (see below).
- **Faster development loops.** Compact observations and runtime UI mutations
  let agents try small fixes before another build/run cycle.

## How it works

Reticle runs a tiny HTTP server **inside** the app process, bound to loopback,
and a host-side CLI talks to it over `adb forward`. The agent captures the live
UI tree from inside the process; the CLI resolves selectors and dispatches real
input.

| Concern | Android | iOS |
| --- | --- | --- |
| Get code into the process | Link the `reticle-agent` AAR — a no-op `ContentProvider` auto-starts the server, no app code changes. For a **debuggable** app without the AAR, `reticle app inject` loads a payload dex over JDWP: no repackage, no root, works even on locked `user` builds where `wrap.sh` is blocked. Non-debuggable release builds still need Frida/root. | Link `ReticleKit` and call `Reticle.start()` (or let the DYLD constructor do it). `app inject` uses `DYLD_INSERT_LIBRARIES` on the simulator; a self-signed debug build can also be injected on a device (`scripts/inject-ios-device.sh`). |
| Talk to the running app | In-process `ReticleServer` on `127.0.0.1`, reached via `adb forward`. | Same loopback server, reached directly (simulator) or over `iproxy` (device). |
| Capture the UI | `WindowManagerGlobal` roots + reflected View properties, merged with the Compose **semantics** tree. | `UIWindow`s + reflected UIKit properties, merged with SwiftUI's **accessibility** elements (`axElement`). |
| Read embedded web content | Read-only DOM bridge on `android.webkit.WebView`. A **third-party kernel** (X5/TBS, UC) cannot be bridged at all — marked `dom:unsupported-kernel` rather than reported as an empty page. | Same bridge on `WKWebView`; iOS has one web engine, so the kernel case cannot arise. |
| Synthesize input | `adb shell input` (tap / swipe / drag / type) — public and stable. | CoreSimulator HID on the simulator; in-process `act activate` on a device, which has no host-reachable HID surface. |
| Selector resolution | Semantic tree first, view-tree frames as fallback; `testId` / `resourceId` / `css` / `ref` / `label` / raw point — one order for both platforms. | Same, pinned from both languages by `reticle-protocol/fixtures/selector-resolution.cases.json`. |

Two rules hold on both platforms. The loopback port is derived per-app from the
bundle id / `applicationId` and computed identically on both ends, so linked apps
never collide on a fixed port. And selectors come only from the
semantics/accessibility surface, never from private framework internals — an
element with no accessibility identity is documented as unaddressable rather than
guessed at.

See `docs/architecture.md` for the full design, including the Compose-semantics
boundary and the injection trade-offs — and `docs/boundaries.md`, which
collects everything an in-process observer cannot reach (closed shadow roots,
cross-origin frames, third-party WebView kernels, bitmap-baked text, out-of-process
system UI, the screenshot's blind spots) next to the evidence Reticle emits for each
instead of returning a plausible-looking nothing.

## Style evidence

`ui style` reports every node's geometry and style properties — spacing, colours,
font size/weight/family/line height, corner radius, borders — each value in the
units a comparison needs and each labelled with the channel it was read through:

```
screen: 1080x2400px density=3 fontScale=1 -> 360x800dp
#checkout.payButton button "Pay now"
    frame  24,1800 1032x120px | 8,600 344x40dp | 95.6%x5% of screen
    cornerRadius  24px | 8dp  [drawableReflect]
    paddingLeft   48px | 16dp  [viewField]
    textSize      42px | 14dp | 14sp  [viewField]
    ! fontFamily  unreadable: android-typeface-exposes-no-family
```

Three things it does that a screenshot cannot. Lengths come out in **dp** as well
as raw pixels, so the same screen on a 320dp and a 411dp device is directly
comparable, and text also comes out in **sp**, which divides out the system font
scale — separating "the app asked for the wrong size" from "the user enlarged
text". A property Reticle cannot read is **named with a reason** instead of being
absent, so "the app sets no font family" and "there is no channel to it" stop
looking identical. And every value carries its **channel**, because a live view
field and a reflected `Drawable` are not equally trustworthy.

It is deliberately not a comparison. What the values ought to be, what tolerance
counts, and which regions are exempt are the caller's policy — so the same output
serves a design-fidelity check, a cross-build diff, or the same screen on two
devices, and Reticle does not need to know which.

```bash
reticle ui style snapshot.json
reticle ui style --live --package <pkg>
```

## Multi-region controls

A single View can carry several tap targets — the classic case is an agreement
row: *"I have read and agree to [Terms][Privacy]"*, where the text toggles a
checkbox and each link opens a different page. Both the view tree and the
semantic tree collapse this into one node. Reticle decomposes it through
several channels:

- **`span`** — real `ClickableSpan` / `URLSpan` ranges, with per-line pixel
  hit-rects and the link's color.
- **`a11yVirtual`** — virtual accessibility sub-nodes (`ExploreByTouchHelper`),
  under whichever virtual-id convention the app chose.
- **`touchDelegate`** — extended/forwarded hit-rects (API 29+), unlabelled, so
  they are addressed as `--region touchDelegate`.
- **`textMarker`** — one region per in-text bracketed / markdown link on
  self-drawn rows, each with its own rect. Bracket detection is script-agnostic
  (markdown `[text](url)`, plus paired delimiters like `«…»` and `《…》`).
- **`colorSpan`** — a re-colored run (the "highlight = link" pattern), surfaced
  with its actual color.
- **char grid** — exact per-character X positions from the laid-out text, so an
  agent can hit any phrase by substring even when nothing structural marks it
  (robust across font, size, letter/line spacing — all read from `Layout`).

Region matching is plain substring matching — pass the on-screen text in any
language.

```bash
reticle ui regions snapshot.json
reticle act tap --package <pkg> --test-id agreement --region "Privacy"
reticle act tap --package <pkg> --test-id agreement --region "Terms"
```

## Install as a Claude Code plugin

Reticle ships as a Claude Code plugin. Add this repo as a marketplace and
install:

```text
/plugin marketplace add KQAR/Reticle
/plugin install reticle@reticle
```

This makes the `reticle` CLI available on the Bash PATH and adds:

- the **`reticle`** skill — teaches the agent when and how to inspect/drive a
  running Android app;
- **`/reticle:report`** — capture a runtime UI report and summarize the screen;
- **`/reticle:tap`** — tap an element by selector (or by phrase via `--region`)
  and verify the result;
- **`/reticle:inject`** — start the runtime inside a debuggable app that does not
  link the agent.

### Install in Cursor

The same repo doubles as a Cursor plugin — the manifests under `.cursor-plugin/`
mirror `.claude-plugin/` and share the identical `skills/` and `commands/`, so
there is one source of truth for both editors. Add the marketplace and install
`reticle` the same way you would any Cursor plugin; the launcher and CLI
acquisition below are identical (the `reticle` CLI lands on PATH regardless of
which editor installed it).

### How the CLI is obtained

`reticle` is the **Swift host** — a no-JDK native macOS 14+ arm64 binary that drives
Android through a sibling **native helper** (`reticle-helper`, the Kotlin Android
layer compiled by GraalVM native-image). **macOS 14+ arm64 (Apple Silicon) only.**

The launcher resolves it in this order (first hit wins):

1. `$RETICLE_HOST` — explicit path to a `reticle-host` binary.
2. `$RETICLE_HOME/bin` — an unpacked release (`reticle-host` + `reticle-helper`).
3. `RETICLE_FROM_SOURCE=1` — **opt-in** source build (Swift host via `swift`,
   native helper via the bundled Gradle + a GraalVM). For development only.
4. A **prebuilt release** — cached under `~/.reticle/cli`, or freshly downloaded
   (SHA256-verified) from
   [GitHub Releases](https://github.com/KQAR/Reticle/releases). **This is the
   default**; it needs `curl`+`unzip` and network, but **no JDK**.

By default Reticle always uses the prebuilt release — no toolchain required and
**no silent source build**. If the download can't be obtained, the launcher
stops with guidance rather than falling back. Verify with `reticle version`; run
`reticle doctor` to check adb and devices. Pin a fork with `RETICLE_REPO`.

Requirements on the host: Apple Silicon macOS 14+, a connected Android
device/emulator with `adb`, and network for the prebuilt download (or
`RETICLE_FROM_SOURCE=1` + Swift toolchain + a GraalVM).

To develop or test locally without installing: `claude --plugin-dir ./` from the
repo root.

Releasing is a `v*` tag: `.github/workflows/release.yml` builds the
`reticle-macos-arm64.zip` distribution, the agent AAR, and `SHA256SUMS` on a macOS
arm64 runner. `AGENTS.md` has the packaging and version-lockstep rules.

## Modules

- `reticle-protocol` — the language-neutral wire contract: JSON Schema plus golden
  fixtures both language implementations are tested against. Not a build module.
- `reticle-core` (Kotlin) and `reticle-swift` (`ReticleProtocol`) — the two
  implementations of that contract: snapshot / semantic / compact models, the
  derivations, and the host-side renderers. `reticle-core` has no Android
  dependency; `ReticleProtocol` is shared by the iOS agent and the Swift host so
  neither re-ports the protocol.
- `reticle-agent/android` (`:reticle-agent:android`) — Android library (AAR): in-process
  HTTP server, view + Compose-semantics capture, region detection, runtime
  mutation, screenshots, auto-started by a no-op `ContentProvider`.
- `reticle-agent/ios` (`ReticleKit` + `ReticleInjection`) — the iOS twin, built by
  SwiftPM and invisible to Gradle: same server and capture over UIKit plus the
  SwiftUI accessibility bridge, with linked and DYLD-constructor auto-start.
- `reticle-helper` — the Kotlin **Android** host layer: `adb forward`, loopback
  evidence, an `adb input` action backend, JDWP injection. **Not a user-facing
  CLI** — it ships as the no-JDK native `reticle-helper` (GraalVM native-image)
  whose `helper` subcommand is the RPC server the Swift host drives. It exists
  only because JDWP injection is irreducibly JVM-shaped; iOS needs no helper.
- `reticle-host` — the **Swift host CLI** (SwiftPM, macOS 14+ arm64), the
  user-facing `reticle`. Android device commands are RPC calls to the helper;
  **iOS is handled natively in-host** (`simctl`/`devicectl`, loopback HTTP,
  CoreSimulator HID). `reticle serve` owns the local daemon session/event surface
  via Hummingbird 2.25.0, with the capture proxy in its own `ReticleNetworkLane`
  target and the iOS backend in `ReticleHostIos`.
- `sample-app` / `sample-app-ios` — demo apps that link each agent end to end,
  each with an agent-free flavor for testing the injection path.

## Quick Start

```bash
# Build everything
./gradlew assemble

# Install the linked sample app on a booted emulator/device
adb install sample-app/build/outputs/apk/linked/debug/sample-app-linked-debug.apk

# `bin/reticle` is the launcher; RETICLE_FROM_SOURCE=1 opts into a source build
# (needs the Swift toolchain + a GraalVM) instead of a prebuilt release.
export RETICLE_FROM_SOURCE=1
CLI="bin/reticle"

# Launch + forward + wait for the in-app runtime (apps that LINK the agent)
$CLI app launch --package dev.reticle.sample

# Or, for a DEBUGGABLE app without the agent: start it, then inject over JDWP.
# Every command below then works against it unchanged (see the `noagent` flavor).
$CLI app inject --package dev.reticle.sample.noagent

# Capture the sample home report and choose a scenario row
$CLI ui report --package dev.reticle.sample --output reticle-report
$CLI ui compact reticle-report/snapshot.json
$CLI act tap --package dev.reticle.sample --test-id scenario.checkout

# `ui outline` numbers visible targets and caches short-lived aliases. Re-run it
# after navigation; the item i/n hint on repeated rows is not a selector.
$CLI ui outline --live --package dev.reticle.sample
$CLI act tap --package dev.reticle.sample --alias @1

# Act on the app (semantic/selector first, frame fallback)
$CLI ui report --package dev.reticle.sample --output reticle-report
$CLI ui node reticle-report/snapshot.json --test-id checkout.payButton
$CLI act tap --package dev.reticle.sample --test-id checkout.payButton

# A selector miss reports same-kind candidates from the current snapshot, so you
# can re-target with a stable handle instead of falling back to coordinates.

# Embedded WebView DOM: inspect by CSS selector, tap, verify, and keep a trace
$CLI act tap --package dev.reticle.sample --test-id scenario.webview
$CLI ui report --package dev.reticle.sample --output reticle-webview
$CLI ui node reticle-webview/snapshot.json --css '#style-target'
$CLI act tap --package dev.reticle.sample --css '#style-target' \
    --verify 'css=#style-target' \
    --trace-output reticle-traces

# Stitch the recorded traces into a device-framed GIF: the gesture is drawn where
# it landed, before/after. Host-local; Android and iOS traces alike.
$CLI replay gif reticle-traces          # => reticle-traces/replay.gif

# Multi-region controls: one View, several click targets (agreement rows etc.)
$CLI app launch --package dev.reticle.sample
$CLI act tap --package dev.reticle.sample --test-id scenario.agreements
$CLI ui report --package dev.reticle.sample --output reticle-report
$CLI ui regions reticle-report/snapshot.json
$CLI act tap --package dev.reticle.sample --test-id agreement.span     --region "Terms"
$CLI act tap --package dev.reticle.sample --test-id agreement.markdown --region "«Privacy»"

# A lazy list binds only its visible window, so a far-down row has NO node to tap.
# `act scroll-to` drags until the selector resolves inside the container, then
# confirms the position stopped moving; running out of travel fails loudly.
$CLI act tap       --package dev.reticle.sample --test-id scenario.list
$CLI act scroll-to --package dev.reticle.sample --test-id list.item40
$CLI act tap       --package dev.reticle.sample --test-id list.item40

# A target still MOVING is the same problem one step earlier: a rect captured mid
# animation is stale by the time the touch lands. Every selector tap re-resolves
# until the point repeats before dispatching, and says `rectMoved=<dx>,<dy>` when
# the first read HAD gone stale. `--settle` raises the budget for a target known to
# be animating in; `--no-settle` opts out (position only — see docs/architecture.md).
$CLI act tap --package dev.reticle.sample --test-id popup.menuTrigger
$CLI act tap --package dev.reticle.sample --label "Delete item" --settle

# The keyboard is another process's window: never a node, so a covered submit
# button still looks tappable. Snapshots carry screen.keyboard, compact marks
# covered items occluded-by:keyboard, and hide-keyboard dismisses it in-process.
$CLI act tap  --package dev.reticle.sample --test-id scenario.login
$CLI act type --package dev.reticle.sample --test-id login.codeField --text "123456"
$CLI ui compact --live --package dev.reticle.sample   # keyboard: visible … occluded-by:keyboard
$CLI act hide-keyboard --package dev.reticle.sample
$CLI act tap  --package dev.reticle.sample --test-id login.submitButton

# Or skip the hide-keyboard + tap: --submit presses the keyboard's action key
# after the text lands (agent editor action on Android — what React Native's
# onSubmitEditing listens for; HID Return on the iOS simulator).
$CLI act type --package dev.reticle.sample --test-id login.codeField \
    --text "123456" --submit

# Read app-authored runtime logs
$CLI debug logs --package dev.reticle.sample

# Live-patch an allowlisted property without rebuilding
$CLI mutate --package dev.reticle.sample --test-id checkout.status \
    --property text --value "Paid!"
```

All helper-backed commands accept `--json` for machine-readable output. Success
uses `{ "ok": true, "data": ... }`; failures use `{ "ok": false, "error": ... }`.
Text output remains the default for interactive use:

```bash
$CLI doctor --json
$CLI act tap --package dev.reticle.sample --test-id checkout.payButton --verify --json
$CLI ui node --live --package dev.reticle.sample --test-id checkout.status --json
```

## Local session event bus

`reticle serve` starts the local daemon: a Hummingbird-backed localhost REST/SSE
event bus with an append-only session log at
`~/.reticle/sessions/<session>/events.jsonl`, plus a built-in read-only Web
panel for the current action and network timeline. Passing `--proxy-port` also
starts a host capture proxy that publishes `network.request`,
`network.response`, and `network.error` events into the same session. Capture is
powered by the [Loom](https://github.com/KQAR/Loom) engine (consumed as an SPM
library); Reticle normalizes its flows into the session event stream.

```bash
reticle serve --session demo --port 9876 --proxy-port 9090
curl -s http://127.0.0.1:9876/health
curl -N http://127.0.0.1:9876/events/stream
# open http://127.0.0.1:9876/panel
```

For Android capture, add `--proxy-device --serial <id>` to configure the device
global proxy via `adb reverse` + `settings put global http_proxy`; Reticle
restores the prior proxy setting when `serve` exits. Plain HTTP is captured
directly. HTTPS CONNECT tunnels are timed and shown; decrypted HTTPS requires
`--proxy-mitm --proxy-ssl-hosts <host[,host]>`. Reticle generates a local CA under
`~/.reticle/proxy-ca` by default (override with `--proxy-ca-dir <dir>`) and signs
per-host leaf certificates on demand. Add `--proxy-install-ca` to push
`reticle-ca.cer` to the device and open Android Security settings; on Android
11+ CA trust must still be confirmed by the user inside Settings. Apps that do
not trust user CAs, do not opt into user CAs via Network Security Config, or use
certificate pinning remain opaque.

A proxied request body is buffered in memory before it is forwarded upstream, so
it is capped at 64 MiB by default; a larger upload is rejected with `413` and a
`network.error` event rather than growing the daemon's memory. Raise or lower the
cap with `--proxy-max-request-body-mb <n>`.

Existing one-shot commands still work without the daemon. When `serve` is
running, `reticle act ...` writes a trace package under the current session
(`~/.reticle/sessions/<session>/traces`) and publishes it as an `action.trace`
event on a best-effort basis. Pass `--trace-output <dir>` when you want to copy
trace artifacts somewhere outside the session.

### Recording, and reading it back

**Recording is on by default, daemon or not.** With no `serve` running, actions
record into an auto session (`~/.reticle/sessions/auto-<timestamp>/traces`);
commands within 15 minutes of each other join the same one. Reticle prunes only
the sessions it created — eligibility is a marker file it writes, not the name,
so a session you named is never a candidate — keeping the 20 most recent within
a 2 GB budget and saying on stderr what it removed. `RETICLE_NO_AUTO_TRACE=1`
turns auto-recording off; explicit `--trace-output` is unaffected.

`reticle trace log` renders a recorded run as a few lines per action, so
reconstructing a session does not mean opening every 100KB+ snapshot:

```bash
reticle trace log                       # the current recording
reticle trace log reticle-batch         # or any trace directory
reticle trace log --changes 12 --json   # more detail / machine-readable
```

```
recording /Users/you/.reticle/sessions/auto-20260727-190522/traces
ios · dev.reticle.sampleios · 3 actions · 19:05:23 → 19:05:25

1  19:05:23  tap  testId=scenario.checkout  →201,220 semantic:testId
    + r100 [testId=Checkout role=container]
    + r101 [testId=BackButton label="Reticle Sample" role=button]
    …94 more (present 46, label 21, text 20, visible 7)
    ! manifest kept 100 of 517 changes (dropped by field: frame 86, role 52, …)
    evidence 1785150323632-tap/, 2 snapshots, 2 screenshots

2  19:05:24  type  testId=checkout.nameField  →201,557 selector  text="Ada Lovelace"
    …

3  19:05:25  tap  testId=checkout.payButton  →201,349 semantic:testId
    ~ r13 text "Cart: 3 items" → "Paid!" [testId=checkout.status label="Paid!" role=text]
    evidence 1785150325765-tap/, 2 snapshots, 2 screenshots
```

Three properties make this readable rather than merely short. Each change
**names the node it is about** (`[testId=…]`), attached once per ref, so a bare
`r13` never sends you to the snapshot. The diff is **ranked before it is capped**
— appearances and text ahead of pixel-level `frame` churn, addressable nodes
ahead of anonymous layout containers — so what survives a cap is what mattered.
And every loss is **counted, not silent**: `…N more` for the render, `! manifest
kept X of Y` for the capture. An action that changed nothing says
`(no observable change between before and after)`, which is a finding, not a
blank.

`trace log` only reads. It is not a replay script and asserts nothing: whether a
run passed is the reader's call, and `--verify` / `act wait --strict` remain the
places to state an expectation.

### Warm paths and command routing

One-shot commands take a warm path by default: the first helper-backed command
fork-execs a small per-device `reticle helper-daemon` (Unix socket under
`~/.reticle/helperd/`), and every later command reuses its resident helper —
no per-command helper spawn. The daemon exits on its own after 600s idle and
removes its socket; `--no-daemon` / `RETICLE_NO_DAEMON=1` opts out, and any
daemon bring-up failure silently falls back to a direct helper spawn.

Alternatively, when `reticle serve` is already running you can route commands
through its helper broker instead:

```bash
reticle serve --session demo --helper-broker
RETICLE_USE_DAEMON=1 reticle status --package dev.reticle.sample
reticle act tap --use-daemon --package dev.reticle.sample --test-id checkout.payButton
```

`--helper-broker` keeps one `reticle-helper` process alive behind the daemon's
localhost HTTP surface. `--use-daemon` (or `RETICLE_USE_DAEMON=1`) forwards the
same helper-backed command RPC through that process, so short command sequences
avoid repeated helper startup. Device selection still follows the normal
`--serial` rule; a per-command `--serial` overrides the broker default for that
request.

`reticle status --package <pkg>` also keeps a small local
`~/.reticle/process-state.json` baseline. If a later status sees the app PID
change, the process disappear, or the runtime move from healthy to an unhealthy
state, text output includes an `advisory:` line and JSON output includes an
`advisory` object. When `serve` is running, the same advisory is published as a
`runtime.advisory` event.

Snapshots and screenshots are referenced from `refs` instead of inlined. The
panel flattens each action trace into a vertical evidence timeline — screenshot
evidence, the action, screenshot evidence, the diff — with network requests
grouped by request id on the other side of a centered axis, sensitive header
values redacted, and a picker that switches between the live session and
historical ones under `~/.reticle/sessions`. It is display-only: it never drives
input or mutates app state. `reticle-protocol/events.md` documents the panel's
full surface (filters, rule groups, copy-as-rule) alongside the REST/SSE contract.

## Traffic rules and flow replay

While `serve` is running, `reticle rule` can reshape traffic in the host proxy
without touching the app. A rule matches traffic and applies an action —
`mock` (a stored fixed response), `block` (fail the connection), `mapRemote`
(re-target another origin), or `passthrough` — plus optional modifiers
(`--delay-ms`, header rewrites, find/replace substitutions). Rules and reusable
response values are stored separately in the current session:

```bash
reticle rule set --id users --action mock --value-id users-ok \
  --method GET --url /api/users --match prefix --priority 100 \
  --status 200 --headers '{"Content-Type":"application/json"}' \
  --body '{"users":[]}'
reticle rule set --id kill-analytics --action block --method ANY --url /track --match prefix
reticle rule set --id slow-home --action passthrough --delay-ms 3000 --method GET --url /api/home --match prefix
reticle rule disable --id users
reticle rule list
```

HTTP rules apply directly. HTTPS rules require MITM decryption and app trust in
the Reticle CA; opaque CONNECT tunnels and pinned/untrusted HTTPS traffic remain
unmodifiable by design. `prefix` is a raw string prefix, so prefer `exact` for
short paths such as `/sa` that could also match unrelated paths like `/sample`.

`reticle replay flow <request-id>` re-sends a captured exchange with optional
overrides (`--method` / `--url` / `--set-headers` / `--remove-headers` / `--body`
/ `--clear-body`). It emits a `network.replay` event and returns the diff against
the original — status, body size, and which header *names* were added, removed or
changed, never their values, so a replay report leaks no credentials:

```bash
reticle replay flow <request-id> --set-headers '{"X-Debug":"1"}' --remove-headers '["Authorization"]'
```

Replay re-sends from the capture engine's bounded in-memory ring, so an older
exchange stays fully evidenced in `events.jsonl` while no longer being replayable;
`GET /sessions/current/flows` stamps every result `replayableOnly` so an empty
list reads as "nothing replayable matches" rather than "this never happened".

## Batching and quick smoke

Quick smoke with the linked sample app:

```bash
reticle app launch --package dev.reticle.sample
reticle act tap --package dev.reticle.sample --test-id scenario.checkout
reticle act tap --package dev.reticle.sample --test-id checkout.payButton \
  --verify '#checkout.status'
```

Short deterministic flows can be sequenced from a JSON file. The Swift host
expands each step into the same single-action helper RPC, stopping on the first
failure. Step keys are the protocol field names, so every selector a single
`act` takes works here too — `testId`, `resourceId`, `css`, `ref`, `point`,
`alias`, `region` — plus `text`/`submit` for type and `from`/`to`/`duration`
for swipe and drag:

```json
[
  { "gesture": "tap", "testId": "scenario.checkout" },
  { "gesture": "tap", "resourceId": "btnWithdraw" },
  { "gesture": "type", "testId": "login.codeField", "text": "123456", "submit": true },
  { "gesture": "tap", "point": "540,1600" },
  { "gesture": "tap", "testId": "checkout.payButton", "verify": "testId=checkout.status" }
]
```

```bash
reticle act batch --package dev.reticle.sample --file steps.json \
  --trace-output reticle-batch

# Stitch the recorded flow into a device-framed animated GIF: before-frames
# show the gesture where it landed (tap ring / swipe arrow), after-frames the
# result, captioned from the trace's gesture + selector. Host-local; works on
# Android and iOS traces alike.
reticle replay gif reticle-batch          # => reticle-batch/replay.gif
```

Expected: `/panel` shows the current session selected in the picker and a
vertical evidence timeline. Each action expands into screenshot evidence, action,
screenshot evidence, and diff cards; the checkout pay diff contains
`checkout.status` changing to `Paid!`.

See `reticle-protocol/events.md` for the REST/SSE surface and event envelope.

## Toolchain

To *run* a prebuilt release: Apple Silicon macOS 14+ + `adb`. No JDK.

To *build from source* (developers):

- Android SDK (compileSdk 35), build-tools, platform-tools (`adb`)
- JDK 17 for Gradle/AGP; a **GraalVM** with `native-image` for the native helper
- the **Swift** toolchain (Xcode) for the host; Hummingbird 2.25.0 makes the host
  target macOS 14+
- Gradle 8.13 (via the wrapper)

Both JDKs can be provisioned in one step with [mise](https://mise.jdx.dev/):
`mise install` in the repo root installs JDK 17 (primary `java`/`JAVA_HOME`)
and a GraalVM 21 whose `native-image` lands on `PATH` — no `GRAALVM_HOME`
needed. This is optional; manually installed JDKs keep working as before.
Xcode/Swift and the Android SDK are managed outside mise (see `mise.toml`).

See `AGENTS.md` for the agent-facing map and architecture rules.

## Inspiration

Reticle was inspired by [Loupe](https://github.com/heoblitz/Loupe), a runtime UI
inspection and action harness for Apple platforms. Reticle applies the same idea
— inspect the app that is actually running, not its source or a screenshot — to
Android, with its own mechanisms for injection, UI capture, and input.

## License

Reticle is released under the [MIT License](LICENSE).
