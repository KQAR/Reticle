# Reticle

**English** | [简体中文](README.zh-CN.md)

Reticle helps AI coding agents build and verify native app interfaces on
**Android** by inspecting the app that is actually running — not just the source
code or a screenshot.

Reticle's job is to *locate and measure* what's on screen: resolve stable
selectors and precise coordinates from the live view / accessibility /
Compose-semantics tree so an agent can act on the right element with confidence.

Tools like `adb`, Espresso, and UiAutomator can build, launch, or drive an app.
Reticle adds the runtime UI layer: structured evidence from the app that is
actually running, so agents can inspect, probe, and verify native interface
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

| Concern | Mechanism |
| --- | --- |
| Get code into the process | Link the `reticle-agent` AAR — a no-op `ContentProvider` auto-starts the server, no app code changes. For a **debuggable** app without the AAR: `reticle app inject` loads a payload dex over JDWP and starts the runtime — no repackage, no root (works even on locked `user` builds where `wrap.sh` is blocked). Non-debuggable release builds still need Frida/root. |
| Talk to the running app | In-process `ReticleServer` on `127.0.0.1`, reached by the CLI via `adb forward`. The port is derived per-app from the `applicationId` (agent and CLI compute the same value), so multiple linked apps never collide on one fixed port. |
| Capture the UI | Walk `WindowManagerGlobal` roots + reflect View properties; merge the Compose **semantics** tree (selectors only from semantics, never private internals). |
| Synthesize input | `adb shell input` (tap / swipe / drag / type) — public and stable. |
| Selector resolution | Semantic tree first, view-tree frames as fallback; `testId` / `resourceId` / `ref` / raw point. |

See `docs/architecture.md` for the full design, including the Compose-semantics
boundary and the injection trade-offs.

## Multi-region controls

A single View can carry several tap targets — the classic case is an agreement
row: *"I have read and agree to [Terms][Privacy]"*, where the text toggles a
checkbox and each link opens a different page. Both the view tree and the
semantic tree collapse this into one node. Reticle decomposes it through
several channels:

- **`span`** — real `ClickableSpan` / `URLSpan` ranges, with per-line pixel
  hit-rects and the link's color.
- **`a11yVirtual`** — virtual accessibility sub-nodes (`ExploreByTouchHelper`).
- **`touchDelegate`** — extended/forwarded hit-rects.
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
  and verify the result.

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

### Releases

Pushing a `v*` tag runs `.github/workflows/release.yml` (on a macOS arm64
runner), which builds and attaches to a GitHub Release:

- `reticle-macos-arm64.zip` — the host + native helper distribution (what the
  launcher downloads; no JDK needed to run);
- `reticle-agent-android.aar` — the agent library to link into a host app build;
- `SHA256SUMS` — checksums for verification.

## Modules

- `reticle-core` — pure JVM snapshot / semantic / compact-observation
  models and the wire protocol. No Android dependency.
- `reticle-agent/android` (`:reticle-agent:android`) — Android library (AAR). In-process
  HTTP server + view and Compose-semantics capture, region detection, runtime
  mutation, screenshots, auto-started by a no-op `ContentProvider`.
  (`reticle-agent/` is a grouping directory reserved for future per-platform
  agents; only the Android child is a Gradle module today.)
- `reticle-helper` — the Kotlin Android host layer: `adb forward` + loopback
  evidence + an `adb input` action backend + JDWP injection. **Not a user-facing
  CLI** — it ships as the no-JDK native `reticle-helper` (GraalVM native-image)
  whose `helper` subcommand is the RPC server the Swift host drives.
- `reticle-host` — the **Swift host CLI** (SwiftPM, macOS 14+ arm64). The user-facing
  `reticle`; owns no device code — device commands are RPC calls to the helper,
  while `reticle serve` owns the local daemon session/event surface via
  Hummingbird 2.25.0.
- `sample-app` — demo app that links the agent end to end.

## Quick Start

```bash
# Build everything
./gradlew assemble

# Install the linked sample app on a booted emulator/device
adb install sample-app/build/outputs/apk/linked/debug/sample-app-linked-debug.apk

# The `reticle` launcher builds + runs the Swift host and native helper from
# source when you opt in (needs the Swift toolchain + a GraalVM). It is the
# user-facing CLI; `reticle-host` / `reticle-helper` are the binaries it drives.
export RETICLE_FROM_SOURCE=1
CLI="bin/reticle"

# Launch + forward + wait for the in-app runtime (apps that LINK the agent)
$CLI app launch --package dev.reticle.sample

# Or, for a DEBUGGABLE app that does NOT link the agent: start it, then inject
# the runtime over JDWP — no repackage, no root. After this, every command below
# works against it unchanged. (See the `noagent` sample flavor.)
$CLI app inject --package dev.reticle.sample.noagent

# Capture the sample home report and choose a scenario row
$CLI ui report --package dev.reticle.sample --output reticle-report
$CLI ui compact reticle-report/snapshot.json
$CLI act tap --package dev.reticle.sample --test-id scenario.checkout

# For agent-facing ad-hoc flows, outline numbers visible targets and caches
# short-lived aliases for the current package. Repeated rows show item i/n.
# Re-run outline after navigation; item i/n is a hint, not a selector.
$CLI ui outline --live --package dev.reticle.sample
$CLI act tap --package dev.reticle.sample --alias @1

# Act on the app (semantic/selector first, frame fallback)
$CLI ui report --package dev.reticle.sample --output reticle-report
$CLI ui node reticle-report/snapshot.json --test-id checkout.payButton
$CLI act tap --package dev.reticle.sample --test-id checkout.payButton

# If a selector misses, Reticle reports same-kind candidates from the current
# snapshot (test ids, resource ids, DOM CSS selectors, or refs) so you can
# re-target with a stable handle before falling back to coordinates.

# Embedded WebView DOM: inspect by CSS selector, tap, verify, and keep a trace
$CLI act tap --package dev.reticle.sample --test-id scenario.webview
$CLI ui report --package dev.reticle.sample --output reticle-webview
$CLI ui node reticle-webview/snapshot.json --css '#style-target'
$CLI act tap --package dev.reticle.sample --css '#style-target' \
    --verify 'css=#style-target' \
    --trace-output reticle-traces

# Stitch the recorded traces into a device-framed animated GIF: before-frames
# draw the gesture where it landed (tap ring / swipe arrow), after-frames show
# the result. Host-local; Android and iOS traces alike.
$CLI replay gif reticle-traces          # => reticle-traces/replay.gif

# Multi-region controls: one View, several click targets (agreement rows etc.)
$CLI app launch --package dev.reticle.sample
$CLI act tap --package dev.reticle.sample --test-id scenario.agreements
$CLI ui report --package dev.reticle.sample --output reticle-report
$CLI ui regions reticle-report/snapshot.json
$CLI act tap --package dev.reticle.sample --test-id agreement.span     --region "Terms"
$CLI act tap --package dev.reticle.sample --test-id agreement.markdown --region "«Privacy»"

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
starts a SwiftNIO host proxy that publishes `network.request`,
`network.response`, and `network.error` events into the same session.

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

Existing one-shot commands still work without the daemon. When `serve` is
running, `reticle act ...` automatically writes a trace package under the current
session (`~/.reticle/sessions/<session>/traces`) and publishes it as an
`action.trace` event on a best-effort basis. Pass `--trace-output <dir>` when you
want to copy trace artifacts somewhere outside the session.

For repeated command loops, start the daemon with a helper broker and point
one-shot commands at it:

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
panel consumes each action trace as a vertical evidence timeline:
screenshot/snapshot evidence nodes, the action, and the compact diff are
flattened into time-ordered cards. Large diffs show a short high-signal preview
first, with text/label/state changes ranked ahead of structural churn and the
full table available on demand. Missing screenshot artifacts render an inline
failure state. The axis is centered so UI evidence can sit on one side while
network request spans occupy the other. Network requests are grouped by request
id with method, URL, status, timing, request/response headers, body artifact
links, and small text previews for captured bodies. Sensitive header values such
as cookies and authorization are redacted. Mocked responses are labeled with the
rule/value ids that produced them. Runtime advisories appear as first-class
timeline cards, and action cards expose copyable selector/target chips for quick
follow-up commands. The session picker can switch between the live current
session and static historical sessions under `~/.reticle/sessions`. It is
display-only: it does not drive input or mutate app state.

While `serve` is running, `reticle mock` can return fixed responses from the
host proxy without touching the app. Rules and response values are stored
separately in the current session:

```bash
reticle mock set --id users --value-id users-ok \
  --method GET --url /api/users --match prefix --priority 100 \
  --status 200 --headers '{"Content-Type":"application/json"}' \
  --body '{"users":[]}'
reticle mock rule disable --id users
reticle mock list
```

HTTP mocks apply directly. HTTPS mocks require MITM decryption and app trust in
the Reticle CA; opaque CONNECT tunnels and pinned/untrusted HTTPS traffic remain
unmockable by design. `prefix` is a raw string prefix, so prefer `exact` for
short paths such as `/sa` that could also match unrelated paths like `/sample`.

Quick smoke with the linked sample app:

```bash
reticle app launch --package dev.reticle.sample
reticle act tap --package dev.reticle.sample --test-id scenario.checkout
reticle act tap --package dev.reticle.sample --test-id checkout.payButton \
  --verify '#checkout.status'
```

Short deterministic flows can be sequenced from a JSON file. The Swift host
expands each step into the same single-action helper RPC, stopping on the first
failure:

```json
[
  { "gesture": "tap", "testId": "scenario.checkout" },
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
