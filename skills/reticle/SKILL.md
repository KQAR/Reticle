---
name: reticle
description: >-
  Inspect and drive a RUNNING Android app from its live runtime, not its source
  or a screenshot. Use when the task involves an Android app on a connected
  device/emulator and you need to: read the on-screen view / semantic /
  Jetpack Compose semantics tree or embedded WebView DOM, find a stable selector
  or exact tap coordinates, tap/swipe/type real input, target a specific phrase
  or link inside a multi-region control (e.g. an agreement row), inspect DOM CSS
  styles or image resources, capture an action trace with before/after evidence,
  read app runtime logs, or live-patch a UI property (text/color/size/visibility)
  without rebuilding.
  Triggers: "inspect the running Android app", "tap the … button on device",
  "what's on screen", "drive the app", "find the element", "test the agreement
  checkbox", "change this label at runtime", adb/UiAutomator/Espresso-style UI
  verification.
---

# Reticle — Android runtime UI evidence + action harness

Reticle inspects the app that is **actually running** and drives real input. It
runs a tiny HTTP server inside the app process (loopback) and a host CLI talks
to it over `adb forward`. Prefer Reticle over guessing from screenshots when you
need precise selectors, coordinates, or live UI state.

The CLI is on PATH as `reticle` while this plugin is enabled.

## Install (how the `reticle` binary is obtained)

`reticle` is the **Swift host** — a no-JDK native macOS 14+ arm64 binary that drives
Android through a sibling native helper (`reticle-helper`). **macOS 14+ arm64 only.**
The launcher (`bin/reticle`) resolves it in this order, first hit wins:
1. `$RETICLE_HOST` — explicit path to a `reticle-host` binary.
2. `$RETICLE_HOME/bin` — an unpacked release (`reticle-host` + `reticle-helper`).
3. `RETICLE_FROM_SOURCE=1` — **opt-in** source build (Swift host + native helper;
   needs the Swift toolchain + a GraalVM with native-image). Development only.
4. A **prebuilt release** — cached under `~/.reticle/cli`, else downloaded
   (SHA256-verified) from GitHub Releases. **This is the default** (needs
   `curl`+`unzip` and network; **no JDK**).

By default the prebuilt release is always used — there is **no silent source
build**. If it can't be obtained the launcher stops with actionable guidance.
`reticle version` confirms it's ready.

## Prerequisites (check, don't assume)

- The CLI is installed/buildable: `reticle version` (any output means it's ready).
- A booted device/emulator in the **`device`** state: `reticle doctor`. It now
  flags `offline`/`unauthorized` devices explicitly — those can't be driven until
  fixed (re-plug USB / accept the on-device debugging prompt).
- **One** target device. With several attached (e.g. a phone + a stray emulator),
  every driving command fails fast listing the candidates — scope it with a global
  `--serial <id>` (or export `ANDROID_SERIAL`, which Reticle also honors). `doctor`
  always lists them all regardless.
- `ANDROID_HOME` set, or adb on PATH.
- The target app must expose the Reticle in-process server. Three cases:
  - **Linked app** (you control the build): add the `reticle-agent` AAR — a
    no-op ContentProvider auto-starts the server, no code changes.
  - **Debuggable app without the AAR**: run `reticle app inject --package <pkg>`
    (the app must already be **running**). It loads a payload dex into the live
    process over JDWP and starts the same runtime — **no repackage, no root**,
    works even on locked `user` builds where `wrap.sh` is blocked. After it, every
    other command works unchanged. The target must already hold the `INTERNET`
    permission (real apps do); non-debuggable release builds still need Frida/root.
  - **Truly unreachable** (non-debuggable, no AAR): without an injection path
    `reticle ui report` cannot reach the app — say so rather than inventing data
    (use `reticle debug logcat` to confirm no agent, and `reticle ui screenshot`
    to still see the screen). The bundled `sample-app` links the agent (the
    `noagent` flavor is the test target for `app inject`).

## Ports are per-app (no more 8765 collisions)

Device loopback ports are **process-global**, so if every linked app bound one
fixed port only the first to start would win and a host `adb forward` could land
on the *wrong* app. Reticle derives each app's port from its `applicationId`
(stable FNV-1a hash into `8765..9764`); the agent binds it and the CLI computes
the same value from `--package`, so no two apps collide and no discovery
round-trip is needed. Override with `RETICLE_PORT` in the app + `--port` on the
CLI. You normally never pass `--port`.

## Health & conflict checks (run when something looks wrong)

Before any snapshot/act/mutate Reticle does a fast (~2s) classified probe of
`/runtime` and fails with a precise message instead of hanging ~15s on a socket
timeout. Use `status` to inspect the live state:

```bash
reticle status                       # device readiness + what the registry knows
reticle status --package <pkg>       # full probe: app running? port? runtime health + identity
reticle debug logcat                 # the agent's OWN startup lines (works even when HTTP is dead)
```

`status` reports one of: **HEALTHY** (and whether the identity matches the
requested package — a mismatch is a port **CONFLICT** with another linked app),
**UNREACHABLE** (connection refused — app not running or agent not linked; status
cross-checks `debug logcat` to tell *not-linked* from *bound-port-failed*),
**UNRESPONSIVE** (connected but no response — stale socket / hung server; fix
with `adb shell am force-stop <pkg>` then relaunch), or **FOREIGN** (some other
server on the port — pick a different `--port`).

`doctor`/commands also pre-check device readiness: an `offline` device triggers a
bounded `adb reconnect`, and `unauthorized`/`offline` produce an actionable error
instead of a 30s hang.

## Screenshots without the agent

`reticle ui screenshot [--package <pkg>] [--output shot.png]` uses the agent's
`/screenshot` when the runtime is reachable, and otherwise falls back to
`adb exec-out screencap`. This is the honest degraded mode for apps that don't
link the agent: you can still see the screen (and drive it via `adb`-backed
`act`/`--point`) even when no structured tree is available.

## Core workflow

```bash
reticle doctor                                   # verify adb + devices (flags offline/unauthorized)
reticle app launch  --package <pkg>              # launch + adb forward + wait for runtime (LINKED apps)
reticle app inject  --package <pkg>              # debuggable app w/o the AAR: load+start the runtime over JDWP
reticle status      --package <pkg>              # probe runtime health + identity if anything's off
reticle ui report   --package <pkg> --output reticle-report
reticle ui compact  reticle-report/snapshot.json # token-cheap, one line per interactive/labelled node
reticle ui node     reticle-report/snapshot.json --test-id <id>   # full node
reticle ui node     reticle-report/snapshot.json --css '#pay'      # WebView DOM node
reticle ui tree     reticle-report/snapshot.json --semantics  # semantic tree
```

Send the **compact** observation to reason about the screen; query specific refs
with `ui node` only when you need full properties. Keep the full snapshot on
disk.

**`--live` — inspect the running app without writing a report.** Any `ui` view
(`node`/`compact`/`tree`/`regions`) takes `--live --package <pkg>` instead of a
snapshot path: it pulls the CURRENT tree straight from the runtime and prints it,
writing nothing to disk. Use it for the cheap "what does that one node say right
now?" check — no 300-node report to grep:

```bash
reticle ui node    --live --package <pkg> --resource-id rata   # one node, live
reticle ui compact --live --package <pkg>                      # whole screen, live
```

## Embedded WebView DOM

Reticle folds visible WebView DOM elements into the same snapshot as `domNode`s.
Use CSS selectors when the target is inside a WebView:

```bash
reticle ui node --live --package <pkg> --css '#checkout button.pay'
reticle act tap --package <pkg> --css '#checkout button.pay' --verify 'css=#status'
```

DOM nodes include the screen-space `frame` plus useful `custom` metadata:

- DOM identity: `domTag`, `domId`, `domClass`, `domCssSelector`, `domHref`,
  `domSrc`, `domSrcset`, `domSizes`, `domInputType`.
- Computed layout/style: `domMargin*`, `domStyleDisplay`, `domStyleVisibility`,
  `domStyleOpacity`, `domStylePosition`, `domStyleZIndex`, `domStyleOverflow*`,
  `domStyleColor`, `domStyleBackgroundColor`, `domStyleBackgroundImage`,
  `domStyleFont*`, `domStyleLineHeight`, `domStyleTextAlign`,
  `domStylePadding*`, `domStyleBorder*Width`, `domStyleBorderRadius`,
  `domStyleTransform`, `domStylePointerEvents`.
- Image resources for `<img>`: `domImageCurrentSrc`,
  `domImageNaturalWidth`, `domImageNaturalHeight`, `domImageComplete`.

The DOM bridge is read-only and snapshot-based. It captures the current document's
visible DOM. iframe inner documents, shadow-root internals, pseudo-elements, and
background-image intrinsic dimensions are boundaries unless explicitly added
later. CSS `background-image` itself is still visible as `domStyleBackgroundImage`.

## Acting on the app

Selector resolution is semantic-first, then view-tree frames, then a raw
point — pass `--test-id`, `--resource-id`, `--css`, `--ref`, or `--point x,y`.

```bash
reticle act tap   --package <pkg> --test-id checkout.payButton
reticle act tap   --package <pkg> --css '#web-pay'
reticle act swipe --package <pkg> --from 540,1600 --to 540,400 --duration 300
reticle act drag  --package <pkg> --from x,y --to x,y
reticle act type  --package <pkg> --text "hello"
reticle act type  --package <pkg> --text "你好 / Zażółć"   # non-ASCII OK
```

`act type` types **any** text. ASCII goes through `adb input text` and works
even on apps that don't link/inject the agent. Non-ASCII (CJK, accented Latin,
emoji — which `adb input text` silently drops) is staged on the device clipboard
by the in-process agent and pasted into the focused field, so it **requires a
reachable runtime** and a focused input. Tap the field first.

**`--verify` — act and check the result in one command.** Add `--verify` to any
`act` and Reticle captures the watched node before the gesture, acts, then polls
until it changes (or a ~2s budget elapses) and prints the before→after diff.
Bare `--verify` watches the node you're acting on; `--verify <selector>` watches a
*different* node (tap a control, watch its effect). This is the "tap → did it
change?" loop in one call — no follow-up `ui report` + grep:

```bash
reticle act tap --package <pkg> --test-id submit --verify              # watch the tapped node
reticle act tap --package <pkg> --point 292,1273 --verify "@rata"      # tap a tab, watch #rata
#   => verify @rata: changed (1 field)
#        text: 3414,20 zł -> 6072,49 zł
```

A selector token is `#testId`, `@resourceId`, or a bare `ref`. "No change" is an
honest result, not a failure — it means the node didn't move within the budget
(raise it with `--verify-timeout <ms>`). For WebView DOM nodes, use
`css=<selector>` as the verify token:

```bash
reticle act tap --package <pkg> --css '#style-target' --verify 'css=#style-target'
```

## Action traces

Use `--trace-output <dir>` when an action needs a durable evidence package, not
just terminal output. Reticle writes one subdirectory per action containing:

- `trace.json` — manifest with gesture, selector, resolved point/source/ref, and
  compact before→after diff.
- `before.snapshot.json` / `after.snapshot.json` — full trees around the action.
- `before.screenshot.png` / `after.screenshot.png` when the agent screenshot path
  is available.

```bash
reticle act tap --package <pkg> --css '#style-target' \
  --verify 'css=#style-target' \
  --trace-output reticle-traces
```

Prefer traces for bug reports, demos, and multi-step validation where later tools
or humans need to inspect the exact evidence. Keep default `act` calls trace-free
when the inline `--verify` diff is enough.

## Session event bus

Use `reticle serve` when you need a durable local timeline across multiple
commands. It creates `~/.reticle/sessions/<session>/events.jsonl` and exposes
REST/SSE on localhost via Hummingbird:

```bash
reticle serve --session demo --port 9876
curl -N http://127.0.0.1:9876/events/stream
```

When the daemon is running, `act ... --trace-output <dir>` keeps writing the same
trace package and also publishes an `action.trace` event. This is useful for
longer demos, replayable validation, or tools that want to consume trace events.
Do not start `serve` for a simple one-off screen read; `ui report`, `ui node
--live`, and `act --verify` stay the cheaper default paths.

## Multi-region controls (one View, several tap targets)

Agreement rows, "highlight = link" text, and self-drawn controls pack several
targets into one node. List them, then tap a specific phrase/link by substring:

```bash
reticle ui regions reticle-report/snapshot.json
reticle act tap --package <pkg> --test-id agreement --region "Privacy"
reticle act tap --package <pkg> --test-id agreement --region "Terms"
```

`ui regions` reports `span` / `colorSpan` / `textMarker` regions (with rects and
link color) and flags `suspectedMultiRegion` self-drawn controls that are still
targetable by substring via the char grid. A `colorSpan` is a *candidate* link
(colored text) — weigh it, don't assert it.

Region matching is plain substring matching and is **script-agnostic** — pass
whatever text appears on screen, in any language (e.g. `--region "Política"`).
The `textMarker` channel splits self-drawn rows on paired bracket delimiters
across scripts (the markdown `[text](url)` form, plus quote/title brackets like
`«…»` and `《…》`).

## Logs and live UI patching

```bash
reticle debug logs --package <pkg>               # app-authored runtime logs
reticle mutate --package <pkg> --test-id <id> --property text       --value "New label"
reticle mutate --package <pkg> --test-id <id> --property textColor  --value "#FFE53935"
reticle mutate --package <pkg> --test-id <id> --property textSize   --value "72"
reticle mutate --package <pkg> --test-id <id> --property backgroundColor --value "#FF0000"
```

Mutations are allowlisted (`text`, `textColor`, `textSize`, `backgroundColor`,
`alpha`, `visibility`, `enabled`), run in-process, and are NOT persisted — a
rebind or restart reverts them. Compose nodes are intentionally immutable here;
drive declarative UI through the app's own state.

## Rules

- Verify with evidence: check the changed node/state after an action — don't
  claim success from the tap alone. Prefer the cheap paths: `act … --verify` to
  see the before→after diff in the acting command, `act … --trace-output` when
  you need durable before/after artifacts, or `ui node --live` to read one node.
  Fall back to a full re-`ui report` only when you need the whole tree.
- If the runtime is unreachable (app not linked / not injected), report that
  honestly; never fabricate a tree or coordinates. For a debuggable app without
  the AAR, try `reticle app inject --package <pkg>` before giving up.
- Authorized testing only: injecting into an app you don't own requires explicit
  authorization. Default to the bundled `sample-app` for demos.

For architecture, the Compose-semantics boundary, and the region/char-grid
design, see `${CLAUDE_PLUGIN_ROOT}/docs/architecture.md` and
`${CLAUDE_PLUGIN_ROOT}/AGENTS.md`.
