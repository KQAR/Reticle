# Reticle Agent Guide

This repository is a Gradle/Kotlin project for Reticle, an Android runtime
inspection, diagnostic, and action harness — it inspects the app that is
actually running, resolves precise selectors and tap regions, and drives real
input through adb.

Use this file as a map. Deeper architecture lives in `docs/architecture.md`.

## Current Shape

- `reticle-core`: pure JVM snapshot models, semantic tree models, compact
  observations, wire protocol, selectors. No Android dependency. Shared by the
  CLI and the in-app agent.
- `reticle-agent/android` (`:reticle-agent:android`): Android library (AAR).
  In-process loopback HTTP server, view-tree + Compose-semantics capture,
  allowlisted runtime mutation, in-process screenshot, app-authored log/metadata
  bridge, and an auto-start `ContentProvider`. `reticle-agent/` is a grouping
  directory (no build.gradle); per-platform agents are its children.
- `reticle-cli`: host JVM CLI for report, screenshot, compact, node, tree,
  regions, tap/swipe/drag/type, logs, logcat, mutate, launch, **inject**, status,
  doctor, version. Talks to the agent over `adb forward`; gates every runtime
  call behind a fast classified `/runtime` probe (health + package identity).
  `app inject` (`Injector.kt` + `Jdwp.kt`, a dependency-free JDWP client) loads
  the payload dex into a debuggable app over the debugger channel and starts the
  runtime — no AAR, no repackage, no root. The three platform-specific seams
  (device control, injection, input) sit behind a `dev.reticle.cli.platform` SPI;
  the Android implementation (`Adb`/`Injector`/`InputBackend`/`Jdwp`) lives under
  `platform/android`, selected via `--target` (default `android`). Adding a
  platform = a new `platform/<os>` implementation, no dispatcher changes.
  This binary is primarily the **Android helper** for the Swift host: its
  `helper` subcommand (`Helper.kt`) is a long-lived JSONL RPC server, and it
  ships as the no-JDK native `reticle-helper` (GraalVM native-image, built by
  `:reticle-cli:nativeHelper`). Direct user-facing commands are **gated off by
  default** (`RETICLE_DIRECT_CLI=1` for the dev fallback). RPC contract:
  `reticle-protocol/helper-rpc.md`.
- `reticle-host`: the **Swift host CLI** (`reticle-host/`, SwiftPM, macOS arm64,
  outside the Gradle build). The user-facing `reticle`; owns no device code —
  every command is an RPC call to the native helper it spawns. At command parity
  with the direct CLI (`app`/`ui`/`act`/`mutate`/`debug`/`status`/`doctor`).
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
  agent AAR on a `v*` tag, from a macOS arm64 runner. No JDK to run. macOS arm64 only.
- `skills/reticle/SKILL.md` — model-invoked skill describing the workflow.
- `commands/report.md`, `commands/tap.md` — slash commands (`/reticle:report`,
  `/reticle:tap`).

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
- JDK 17 for Gradle/AGP. The build **pins the Gradle daemon to JDK 17** via
  `gradle/gradle-daemon-jvm.properties` (`toolchainVersion=17`), so the wrapper
  auto-selects a locally-installed 17 even when the default `java` is newer —
  no `JAVA_HOME` needed. (A too-new default like JDK 26 otherwise crashes the
  daemon and AGP 8.7.) If no JDK 17 is auto-detected, install one or set
  `JAVA_HOME=$(/usr/libexec/java_home -v 17)` as a fallback.
- Gradle 8.13 via the wrapper.

## Verification

Build everything (the daemon auto-pins to JDK 17 — see Toolchain):

```bash
./gradlew assemble
```

Prove the runtime round trip on a booted device/emulator:

```bash
./gradlew :reticle-cli:installDist :sample-app:assembleDebug
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

Expected: tap resolves via `semantic:testId`, the status text flips to
"Paid!" after the tap, and the logs include `checkout_visible` /
`checkout_paid`.

Prove the **unlinked** (JDWP injection) path on the `noagent` flavor:

```bash
JAVA_HOME=$(/usr/libexec/java_home -v 17) ./gradlew \
  :reticle-cli:installDist :reticle-agent:android:dexPayload :sample-app:assembleNoagentDebug
adb install -r -t sample-app/build/outputs/apk/noagent/debug/sample-app-noagent-debug.apk
adb shell monkey -p dev.reticle.sample.noagent -c android.intent.category.LAUNCHER 1

CLI=reticle-cli/build/install/reticle/bin/reticle
$CLI app inject --package dev.reticle.sample.noagent   # loads the dex over JDWP, starts the runtime
$CLI ui report  --package dev.reticle.sample.noagent --output /tmp/reticle-noagent
```

Expected: `app inject` prints `runtime live: … port=…`, and `ui report` returns a
non-empty tree (`#checkout.payButton`, the agreement rows) — proving the runtime
is serving inside an app that carries none of `dev.reticle.agent.*`. Set
`RETICLE_JDWP_DEBUG=1` for a step trace if it stalls. The dex must be read-only
on-device (the CLI does this) or ART's W^X policy rejects it.

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
- Injection into apps without the AAR: `reticle app inject` over JDWP for any
  **debuggable** app (no repackage, no root — works on locked `user` builds where
  `wrap.sh` is blocked); the payload dex is built by `:reticle-agent:android:dexPayload`
  and resolved via the `reticle.payloadDex` sysprop / `$RETICLE_PAYLOAD_DEX` →
  gradle build output → `<cli>/lib/` (the helper RPC sets the sysprop explicitly).
  Non-debuggable release builds still need Frida/root. See `docs/architecture.md`
  for the JDWP sequence and its on-device constraints.
