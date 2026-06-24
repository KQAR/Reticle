---
name: reticle
description: >-
  Inspect and drive a RUNNING Android app from its live runtime, not its source
  or a screenshot. Use when the task involves an Android app on a connected
  device/emulator and you need to: read the on-screen view / accessibility /
  Jetpack Compose semantics tree, find a stable selector or exact tap
  coordinates, tap/swipe/type real input, target a specific phrase or link
  inside a multi-region control (e.g. an agreement row), read app runtime logs,
  or live-patch a UI property (text/color/size/visibility) without rebuilding.
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

The CLI is on PATH as `reticle` while this plugin is enabled. The first
invocation builds the CLI from the bundled sources (one-time, ~30s); later calls
are instant.

## Prerequisites (check, don't assume)

- A booted device/emulator: `reticle doctor` (lists adb path + devices).
- `ANDROID_HOME` set, or adb on PATH. The launcher needs JDK 17 to build once.
- The target app must expose the Reticle in-process server. Two cases:
  - **Linked app** (you control the build): add the `reticle-agent` AAR — a
    no-op ContentProvider auto-starts the server, no code changes.
  - **App without the agent**: requires an injection path (wrap.sh for
    debuggable, or Frida/root). Without it, `reticle ui report` cannot reach the
    app — say so rather than inventing data. The bundled `sample-app` links the
    agent and is the easiest way to see the full loop.

## Core workflow

```bash
reticle doctor                                   # verify adb + devices
reticle app launch  --package <pkg>              # launch + adb forward + wait for runtime
reticle ui report   --package <pkg> --output reticle-report
reticle ui compact  reticle-report/snapshot.json # token-cheap, one line per interactive/labelled node
reticle ui node     reticle-report/snapshot.json --test-id <id>   # full view-tree node
reticle ui tree     reticle-report/snapshot.json --accessibility  # a11y tree
```

Send the **compact** observation to reason about the screen; query specific refs
with `ui node` only when you need full properties. Keep the full snapshot on
disk.

## Acting on the app

Selector resolution is accessibility-first, then view-tree frames, then a raw
point — pass `--test-id`, `--resource-id`, `--ref`, or `--point x,y`.

```bash
reticle act tap   --package <pkg> --test-id checkout.payButton
reticle act swipe --package <pkg> --from 540,1600 --to 540,400 --duration 300
reticle act drag  --package <pkg> --from x,y --to x,y
reticle act type  --package <pkg> --text "hello"
```

## Multi-region controls (one View, several tap targets)

Agreement rows, "highlight = link" text, and self-drawn controls pack several
targets into one node. List them, then tap a specific phrase/link by substring:

```bash
reticle ui regions reticle-report/snapshot.json
reticle act tap --package <pkg> --test-id agreement --region "《Privacy》"
reticle act tap --package <pkg> --test-id agreement --region "用户协议"
```

`ui regions` reports `span` / `colorSpan` / `textMarker` regions (with rects and
link color) and flags `suspectedMultiRegion` self-drawn controls that are still
targetable by substring via the char grid. A `colorSpan` is a *candidate* link
(colored text) — weigh it, don't assert it.

## Logs and live UI patching

```bash
reticle debug logs --package <pkg>               # app-authored runtime logs
reticle mutate --package <pkg> --test-id <id> --property text       --value "新文案"
reticle mutate --package <pkg> --test-id <id> --property textColor  --value "#FFE53935"
reticle mutate --package <pkg> --test-id <id> --property textSize   --value "72"
reticle mutate --package <pkg> --test-id <id> --property backgroundColor --value "#FF0000"
```

Mutations are allowlisted (`text`, `textColor`, `textSize`, `backgroundColor`,
`alpha`, `visibility`, `enabled`), run in-process, and are NOT persisted — a
rebind or restart reverts them. Compose nodes are intentionally immutable here;
drive declarative UI through the app's own state.

## Rules

- Verify with evidence: after an action, re-`ui report` and check the changed
  node/state — don't claim success from the tap alone.
- If the runtime is unreachable (app not linked / not injected), report that
  honestly; never fabricate a tree or coordinates.
- Authorized testing only: injecting into an app you don't own requires explicit
  authorization. Default to the bundled `sample-app` for demos.

For architecture, the Compose-semantics boundary, and the region/char-grid
design, see `${CLAUDE_PLUGIN_ROOT}/Docs/Architecture.md` and
`${CLAUDE_PLUGIN_ROOT}/AGENTS.md`.
