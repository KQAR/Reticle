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

`reticle` is the **Swift host** — a no-JDK native macOS arm64 binary that drives
Android through a sibling **native helper** (`reticle-helper`, the Kotlin Android
layer compiled by GraalVM native-image). **macOS arm64 (Apple Silicon) only.**

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

Requirements on the host: Apple Silicon macOS, a connected Android
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
- `reticle-host` — the **Swift host CLI** (SwiftPM, macOS arm64). The user-facing
  `reticle`; owns no device code — every command is an RPC call to the helper.
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

# Act on the app (semantic/selector first, frame fallback)
$CLI ui report --package dev.reticle.sample --output reticle-report
$CLI ui node reticle-report/snapshot.json --test-id checkout.payButton
$CLI act tap --package dev.reticle.sample --test-id checkout.payButton

# Embedded WebView DOM: inspect by CSS selector, tap, verify, and keep a trace
$CLI act tap --package dev.reticle.sample --test-id scenario.webview
$CLI ui report --package dev.reticle.sample --output reticle-webview
$CLI ui node reticle-webview/snapshot.json --css '#style-target'
$CLI act tap --package dev.reticle.sample --css '#style-target' \
    --verify 'css=#style-target' \
    --trace-output reticle-traces

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

## Toolchain

To *run* a prebuilt release: Apple Silicon macOS + `adb`. No JDK.

To *build from source* (developers):

- Android SDK (compileSdk 35), build-tools, platform-tools (`adb`)
- JDK 17 for Gradle/AGP; a **GraalVM** with `native-image` for the native helper
- the **Swift** toolchain (Xcode) for the host
- Gradle 8.13 (via the wrapper)

See `AGENTS.md` for the agent-facing map and architecture rules.

## Inspiration

Reticle was inspired by [Loupe](https://github.com/heoblitz/Loupe), a runtime UI
inspection and action harness for Apple platforms. Reticle applies the same idea
— inspect the app that is actually running, not its source or a screenshot — to
Android, with its own mechanisms for injection, UI capture, and input.

## License

Reticle is released under the [MIT License](LICENSE).
