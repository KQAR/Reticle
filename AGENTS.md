# Reticle Agent Guide

This repository is a Gradle/Kotlin project for Reticle, an Android runtime
inspection, diagnostic, and action harness — it inspects the app that is
actually running, resolves precise selectors and tap regions, and drives real
input through adb.

Use this file as a map. Deeper architecture lives in `Docs/Architecture.md`.

## Current Shape

- `reticle-core`: pure JVM snapshot models, accessibility tree models, compact
  observations, wire protocol, selectors. No Android dependency. Shared by the
  CLI and the in-app agent.
- `reticle-agent`: Android library (AAR). In-process loopback HTTP server,
  view-tree + Compose-semantics capture, allowlisted runtime mutation,
  in-process screenshot, app-authored log/metadata bridge, and an auto-start
  `ContentProvider`.
- `reticle-cli`: host JVM CLI for report, screenshot, compact, node, tree,
  regions, tap/swipe/drag/type, logs, logcat, mutate, launch, status, doctor,
  version. Talks to the agent over `adb forward`; gates every runtime call
  behind a fast classified `/runtime` probe (health + package identity).
- `sample-app`: demo app that links the agent and proves the round trip.

## Claude Code plugin packaging

The repo is ALSO a Claude Code plugin (and its own single-plugin marketplace),
so it installs over the network with `/plugin marketplace add KQAR/Reticle` then
`/plugin install reticle@reticle`.

- `.claude-plugin/plugin.json` — plugin manifest (`name: reticle`).
- `.claude-plugin/marketplace.json` — marketplace catalog; the plugin entry uses
  `source: "./"` (the repo root is the plugin).
- `bin/reticle` — launcher added to the Bash PATH when the plugin is enabled.
  Default path ALWAYS uses the prebuilt release (SHA256-verified, cached under
  `~/.reticle/cli` or downloaded from Releases) and never silently builds from
  source; if the download fails it hard-stops with guidance. Order:
  `$RETICLE_CLI` → `$RETICLE_HOME` → `RETICLE_FROM_SOURCE=1` (opt-in source build,
  needs JDK 17) → prebuilt release. `release.yml` publishes the prebuilt CLI +
  agent AAR on a `v*` tag.
- `skills/reticle/SKILL.md` — model-invoked skill describing the workflow.
- `commands/report.md`, `commands/tap.md` — slash commands (`/reticle:report`,
  `/reticle:tap`).

Validate after changing any manifest/skill/command: `claude plugin validate .`
locally. CI runs a dependency-free check instead
(`python3 scripts/validate_plugin.py`): well-formed JSON + required fields +
in-repo source paths exist.
Only `plugin.json` lives under `.claude-plugin/`; `skills/`, `commands/`, `bin/`
stay at the repo (plugin) root.

## Architecture Rules

- The agent observes app state. It is not the place where input events are
  synthesized — real input comes from the host via `adb shell input`.
- Use the view tree for UI/layout/style validation. Use the accessibility tree
  first for movement and input; selector actions fall back to view frames only
  when no accessibility match exists.
- Reticle does not synthesize a Compose view tree. Compose elements are valid
  movement/input targets only when exposed through the SemanticsNode tree
  (`Modifier.testTag`, contentDescription). Never invent selectors from private
  Compose internals.
- The CLI exposes `tap`, `swipe`, `drag`, and `type`. `pinch` keeps the API
  shape but is not implemented (needs `sendevent` multi-touch).
- Keep full snapshots on disk. Send compact observations to agents by default,
  then query or inspect specific refs on demand.
- Runtime mutation is allowlisted (`alpha`, `visibility`, `text`,
  `backgroundColor`, `enabled`). Compose nodes are intentionally not mutable;
  drive declarative UI through app-owned state.

## Toolchain

- Android SDK at `~/Library/Android/sdk` (compileSdk 35, build-tools present).
- JDK 17 for Gradle/AGP (`/usr/libexec/java_home -v 17`). The default JDK 26 is
  too new for AGP 8.7 — always set `JAVA_HOME` to a 17 JDK before building.
- Gradle 8.13 via the wrapper.

## Verification

Build everything:

```bash
JAVA_HOME=$(/usr/libexec/java_home -v 17) ./gradlew assemble
```

Prove the runtime round trip on a booted device/emulator:

```bash
JAVA_HOME=$(/usr/libexec/java_home -v 17) ./gradlew :reticle-cli:installDist :sample-app:assembleDebug
adb install -r -t sample-app/build/outputs/apk/debug/sample-app-debug.apk

CLI=reticle-cli/build/install/reticle/bin/reticle
export RETICLE_ADB="$ANDROID_HOME/platform-tools/adb"

$CLI app launch  --package dev.reticle.sample
$CLI ui report   --package dev.reticle.sample --output /tmp/reticle-report
$CLI ui compact  /tmp/reticle-report/snapshot.json
$CLI ui node     /tmp/reticle-report/snapshot.json --test-id checkout.payButton
$CLI act tap     --package dev.reticle.sample --test-id checkout.payButton
$CLI debug logs  --package dev.reticle.sample
$CLI mutate      --package dev.reticle.sample --test-id checkout.status \
                 --property text --value "Cart: 3 items"
```

Expected: tap resolves via `accessibility:testId`, the status text flips to
"Paid!" after the tap, and the logs include `checkout_visible` /
`checkout_paid`.

## Known Boundary

- `app launch` uses `monkey ... LAUNCHER` (retried once on a transient adb-shell
  timeout); the agent auto-starts via its `ContentProvider`, so no special launch
  env is needed for linked apps.
- The loopback port is derived per-app from the `applicationId` via
  `PortMap.derivePort` in `reticle-core` (shared verbatim by agent and CLI), so
  multiple linked apps don't collide on one fixed port. `RETICLE_PORT` (app) +
  `--port` (CLI) override it. Changing the hash desyncs both sides — the pinned
  vectors in `PortMapTest` guard against that.
- In-process `/screenshot` won't capture `SurfaceView` / secure windows; the
  CLI can fall back to `adb exec-out screencap` for those (`reticle ui screenshot`).
- Injection into apps without the AAR requires `wrap.sh` (debuggable) or
  Frida/root (release). See `Docs/Architecture.md`.
