# Reticle Roadmap & Multi-Platform Architecture

**English** | [简体中文](roadmap.zh-CN.md)

Status: roadmap and current-state doc (updated 2026-07-16, tracking 0.7.0 plus
Phase 2/3 streaming + schema + panel follow-ups). Captures
the agreed direction for evolving Reticle from a single-platform Android CLI into a
multi-platform runtime harness with an integrated capture proxy and a live web panel.
`docs/architecture.md` describes the current implementation in more operational
detail. The final section, **Proposed next: evidence workflows + security-evidence
lane**, records the next set of not-yet-built proposals that ride on the primitives
already landed through Phase 1–3.

## Vision

The end goal: **post-development E2E and verification** — let an AI agent run a
finished feature end-to-end on a real device and check each step. Crucial scope
decision: **Reticle provides evidence, not verdicts.** The product verb is
*observe / drive / capture*, never *assert*. Reticle faithfully emits state,
trees, network events, screenshots, and action traces; the **agent** (or an
external test framework) decides whether a step passed. So the protocol and
command surface get **no** `assert`/`expect`/`verify` primitives — they get
richer, more comparable *evidence* instead. This keeps the tool honest and
composable, and makes evidence quality (structured, diffable traces and network
events) the thing to optimize.

Reticle today inspects and drives a running Android app from its live runtime
(in-process agent + host CLI over a loopback HTTP/JSON protocol). The roadmap
extends this along three axes without abandoning the project's defining
constraint — **no root, no repackage, no byte-code hooking**:

1. **Multi-platform** — Android first and complete; iOS and HarmonyOS as a
   *thin* reservation (protocol spec + platform interfaces), not built yet.
2. **A whistle-style capture proxy** — a pure host-side MITM proxy subsystem,
   integrated into the same CLI/daemon, for inspecting app network traffic.
3. **A live web panel** — a unified UI showing proxy traffic, app action paths
   (tap/swipe/type sequences), and status screenshots, fed by a long-lived
   daemon.

### The hard capabilities have a real ceiling — on every platform

Prior art in this space (runtime harnesses for other platforms, built on the
same in-process-server + host-CLI shape) confirms that the "deep" capabilities
have a real ceiling, and that the honest boundaries below are not Android
limitations but structural ones:

- Object inspection is **class-metadata reflection**, not heap instance
  enumeration.
- Network capture is **app-cooperative or host-side MITM**, not passive
  interception of arbitrary in-process traffic.
- Arbitrary real-device injection is **out of scope** — a real-device build must
  link the agent at build time.

The cross-platform asset is therefore **the protocol**, not shared source. A
future iOS or HarmonyOS agent interoperates only by speaking the same loopback
contract, in whatever language fits the platform.

## Principle: the protocol is the spine, not the code

The agent and CLI already communicate over loopback HTTP + JSON (9 endpoints in
`reticle-core/Protocol.kt`: `/report` `/snapshot` `/semantics` `/compact`
`/screenshot` `/mutate` `/clipboard` `/runtime` `/logs`). A future iOS (Swift) or HarmonyOS (ArkTS/C++) agent
**does not need to share Kotlin code** — it only needs to produce the same JSON.
The Kotlin types in `reticle-core` are one implementation of the spec; each
platform brings its own.

Therefore the first reservation work is to promote `reticle-core` from "a set of
Kotlin types" to **a language-neutral, versioned protocol spec** (JSON schema +
golden fixtures + contract tests). The Kotlin types become *one implementation*
of that spec. This is the true backbone of multi-platform support and is nearly
free to do now.

**Polyglot monorepo ≠ single build system.** The repo stays a monorepo, but each
platform keeps its native build (Gradle for JVM/Android, SwiftPM for a future
iOS agent, hvigor for HarmonyOS). What is unified is the **host CLI binary** and
the **protocol spec** — not the build. This must be stated explicitly so nobody
tries to drive a Swift build from Gradle.

## Platform seams (only three) — thin reservation

"Abstracting for platforms that don't exist yet" normally risks abstracting
*wrong* (with one implementation you can't see the right interface). But the
seams are evidenced by how comparable harnesses split their platform layers, not
imagined. Only three pieces of the host CLI are platform-specific:

| Seam | Android (today) | iOS (est.) | HarmonyOS (est.) |
| --- | --- | --- | --- |
| **Device control / transport** | `Adb.kt` (forward / push / run-as / pidof / screencap / proxy config) | `xcrun simctl` + CoreSimulator | `hdc` |
| **Injection** | JDWP + payload dex (`Injector`) | DYLD constructor (sim) / linked framework (device) | TBD |
| **Input synthesis** | `adb input` (`InputBackend`) | private CoreSimulator HID | `hdc input` |

The HTTP transport layer (`RuntimeClient`) is **already platform-neutral** — any
platform agent that speaks the protocol works with it unchanged; it needs no
abstraction.

**Reservation = interfaces only, no empty stubs (YAGNI).** Introduce a `Platform`
SPI bundling `DeviceController`, `Injector`, and `InputBackend`; move the current
Android code behind `AndroidPlatform`; have the CLI select platform by
`--target` (default `android`). Do **not** create iOS/HarmonyOS placeholder
modules or "unsupported" stubs — interfaces, not stubs.

Note the asymmetry: only the **agent** (in-process code) is genuinely
platform-specific and gets its own per-platform build (AAR / framework / HAP).
The **CLI** is host-side and stays one module; its three platform seams live as
*source packages* (`dev.reticle.cli.platform.android`), not separate modules.

## CLI is a thin client: derivation lives in the agent

A clarified boundary (it was muddy before). The host CLI must NOT own UI-shaped
algorithms. Capture-derived views are computed **in the agent, on-device**, and
returned as finished JSON; the CLI receives products and does only protocol I/O
(HTTP, JSON, arg parsing, forking `adb`/`simctl`/`hdc`).

| Algorithm | Home | Why |
| --- | --- | --- |
| `SemanticTree.build`, `CompactObservation.from`, selector resolution | **agent** (on-device) | Pure functions over a snapshot; current agents capture once and derive report views in one pass. `ui report` consumes this bundle; selector resolution is the remaining sink-down work. |
| `PortMap.derivePort` | **both ends, by spec** | Chicken-and-egg: the CLI needs the device port *before* it can reach the agent, so it can't ask the agent for it. It is a protocol rule (a stable hash of `applicationId`) that each end implements identically. Belongs in `reticle-protocol`, not in shared code. |

Consequence for language choice: once derivation lives in the agent, the CLI's
dependency on `reticle-core` shrinks to **data models only** — and models are not
shared across platforms anyway (each language has its own, aligned by the schema;
see below). So a thin-client CLI is **language-free**: Kotlin/JVM, Swift, Go, or
Rust are all viable, because the CLI just speaks the protocol and shells out to
device tools. The cross-platform contract is the protocol, never shared code.

This means: **the thing that makes the CLI clean is the derivation sink-down and
thin-client shape — not the implementation language.** Rewriting the CLI in
another language is therefore an optional preference, not an architectural
necessity. JVM is a fine default for a host tool: mature cross-OS distribution,
no macOS required to build (CI is Linux), and it shares `reticle-core` with the
Android agent for free today. The direction below (Swift host + Kotlin Android
helper) is the chosen long-term shape; until it is executed, the host stays
Kotlin/JVM.

## Direction: Swift host + per-platform helpers (chosen, not yet built)

Decided direction: unify the **host program** (CLI + daemon + Web panel — they
are one process, `reticle serve`, not separate components) onto **Swift**, with
each platform's device dirty-work kept in whatever language fits that platform,
invoked across a process boundary.

Why this shape, and not a full Swift rewrite of everything:

- **JDWP injection cannot sink into the agent.** The whole point of JDWP
  injection is to get the agent into a process that *doesn't have it yet* — the
  agent is the *result* of injection, not a precondition. So the ~680-line JDWP
  codec is irreducibly host-side, and irreducibly Android-specific.
- **Android's dirty-work is most natural in the JVM** (JDWP, dex, `d8`). Rewriting
  it in Swift is the single highest-risk part of any rewrite (every fix in its
  git history is a hard-won ART/dexopt/GC edge case).
- So: keep the **entire current `AndroidPlatform`** (adb + injector + JDWP +
  input) as a **Kotlin `reticle-android-helper`**, and have the Swift host invoke
  it. The existing `Platform` SPI moves out to a *process boundary* intact rather
  than being rewritten.

```
Swift host (CLI + daemon + Web)
├─ generic core: args / HTTP / JSON / event bus / proxy / Web panel
└─ PlatformClient (Swift interface)
   ├─ AndroidHelperClient → talks to `reticle-android-helper` (Kotlin: today's AndroidPlatform)
   ├─ (future) iOS      → native in the Swift host (simctl / DYLD — same ecosystem, no helper)
   └─ (future) harmony  → hdc / helper TBD
```

Note the asymmetry: a helper exists **only when a platform's dirty-work lives in
a non-host ecosystem**. Android (JVM) warrants one; iOS does not (simctl/DYLD are
already native to a Swift/macOS host). Do not over-generalize "helper" to every
platform.

Honest costs (this is not free, it trades rewrite risk for IPC complexity):

- **A full Kotlin/JVM helper remains.** "Whole-Android-via-helper" means the
  helper is the entire current Android host layer (~1137 lines), needing a JVM or
  its own native-image. The JVM dependency is not eliminated — it is collapsed
  into one isolated, language-justified executable.
- **Every Android call becomes cross-process.** `forward`/`screencap`/`input`/
  `logcat` are high-frequency; the helper therefore must be a **long-lived RPC
  service**, not fork-per-call. Its request/response contract belongs in
  `reticle-protocol` alongside the wire protocol.
- **Two long-lived processes.** The Swift daemon and the Kotlin Android helper
  are both resident; the host orchestrates both. The roadmap must keep these
  distinct (a Swift daemon is not the Kotlin helper) to avoid a "two daemons"
  muddle.

Risk posture: this **eliminates the JDWP-rewrite risk entirely** (the Android
code is kept verbatim) and converts "rewrite the hardest code" into "design a
good host↔helper IPC contract + manage two resident processes" — real work, but
low-risk, standard-pattern work. Execution is **spike-first**: prove the
host↔helper RPC before porting the generic core to Swift.

### Status (2026-06-26): a working Swift host CLI exists

The direction is past spike — there is a **real Swift host CLI** driving Android
through the Kotlin helper end-to-end on a real device. What exists today:

- **Kotlin helper** — a `reticle helper` subcommand (`reticle-helper/.../Helper.kt`):
  a long-lived JSONL stdio RPC loop (one request per stdin line, one response per
  stdout line; stdout protocol-only, diagnostics to stderr). Methods (as of 0.7.0):
  `ping`, `listDevices`, `status`, `inject`, `launch`, `uiReport`, `act`, `mutate`,
  `logs`, `logcat`, `screenshot`, `render` (helper-side tree/compact/node/regions/
  outline rendering), and `proxyStatus` / `proxySet` / `proxyClear` /
  `proxyInstallCa` — reusing the existing `Platform` SPI and `RuntimeClient`
  verbatim (the helper *is* today's Android host layer behind an RPC seam). Resident loop, not fork-per-call; a bad/unknown request
  returns a structured error without taking the loop down. `inject` accepts an
  explicit `payloadDex`; `uiReport` fetches the agent-derived `/report` bundle
  and returns the finished `snapshot`/`semantics`/`compact` JSON.
- **RPC contract** — formalized in `reticle-protocol/helper-rpc.md` (envelope,
  methods, the explicit-payload rule, the inject-waits-for-liveness rule).
- **Swift host CLI** — `reticle-host/` (SwiftPM; outside the Gradle build). A
  real CLI at command parity with the Kotlin CLI: `HelperClient` (resident JSONL
  RPC with id correlation) + `doctor` / `devices` / `status` / `app launch|inject`
  / `act` / `mutate` / `debug` / `ui report|screenshot|tree|compact|node|regions`
  / `version`. It owns no device code — every command is an RPC call. `ui report`
  writes the helper-returned trees straight to `snapshot.json` / `semantics.json`
  / `compact.json` (the thin-client boundary in practice — the host never
  re-derives). (The original throwaway spike has been removed now that the real
  host exists.)

Verified on a real device: `doctor`/`devices`/`status` return real device data;
**`ui report` against the linked sample app produced a healthy runtime and wrote
a real 24KB `snapshot.json` + semantics + compact** (nodes=15, compact=8,
semantic=10). So the full value path works through Swift → helper → Android.

One device-side caveat (orthogonal to the host): on the OEM test ROM, `inject`
completes but the runtime does not come up afterward — *identically to the CLI's
own `app inject`*, so it is a ROM JDWP/breakpoint quirk, not a host or boundary
problem. `ui report` was therefore proven via the **linked** sample app (agent
AAR, no JDWP needed); a successful end-to-end *inject* is best confirmed on an
emulator.

**What "Swift host" means at this stage:** the host *CLI* is done and now at
**functional parity** with the Kotlin CLI's one-shot surface. Beyond
doctor/devices/status/inject/ui report, the Swift host also drives `launch`,
`act` (tap/swipe/drag/type, incl. selector and `--region` resolution), `mutate`,
`debug logs`/`logcat`, `ui screenshot` (PNG over base64), and local
`ui tree`/`compact`/`node`/`regions` (rendered by the helper — derivation stays
in Kotlin). All verified on a real device against the linked sample app
(selector tap resolved to coordinates, mutate applied, logs read, a 1080×2412
PNG written, `--region "《隐私政策》"` resolved to a precise point).

The daemon, Web panel, proxy, HTTPS MITM lane, and session-scoped network mocks
now exist in `reticle serve`. Streaming proxy forwarding and a typed `network.*`
schema have since landed too (see Phase 2 below). **Still ahead for the full
Swift host:** reverse-drive panel controls if explicitly chosen later, and
streaming `logs --follow`. JDWP is never rewritten.

## Protocol spec: JSON Schema is authoritative; Kotlin is hand-written + verified

`reticle-protocol/` holds **JSON Schema (2020-12)** files plus golden fixtures as
the single, language-neutral source of truth for the wire contract.

- The Kotlin types in `reticle-core` stay **hand-written** (keeping their doc
  comments and the kotlinx-serialization setup for sealed hierarchies like
  `MetadataValue`, which codegen handles poorly) and a **CI contract test**
  validates the JSON they emit against the schema + fixtures.
- Future greenfield platforms (Swift / ArkTS) may **codegen** their models from
  the same schema. "Generate vs hand-write" is a per-platform choice; the schema
  is the contract everyone shares.

## Target module layout

`reticle-agent/` is a **grouping directory, not a build unit** — it must never
contain its own `build.gradle`. Only `:reticle-agent:android` is `include`d in
Gradle; future `ios/` (SwiftPM) and `harmony/` (hvigor) siblings are invisible to
Gradle by design. (Nesting makes the Gradle leaf project name `android`, so the
module must set `archivesName` explicitly or its AAR would be named `android-…`.)

```
reticle/  (polyglot monorepo — one host binary + one protocol spec)
├─ reticle-protocol/      # JSON Schema (authoritative) + golden fixtures + contract tests  ← spine
├─ reticle-core/          # Kotlin types: hand-written, verified against the schema in CI
├─ reticle-agent/         # GROUPING DIR ONLY (no build.gradle here)
│   ├─ android/           # Gradle module :reticle-agent:android → reticle-agent-android.aar
│   ├─ (future) ios/      # SwiftPM package — invisible to Gradle
│   └─ (future) harmony/  # hvigor module — invisible to Gradle
├─ reticle-helper/        # Kotlin Android host layer → no-JDK native reticle-helper (RPC server)
│   └─ src/.../platform/android/  # AndroidPlatform: Adb / JDWP / InputBackend
├─ reticle-host/          # Swift host CLI + `reticle serve` daemon, panel, proxy/MITM, mocks
└─ sample-app/            # demo linking :reticle-agent:android
```

---

# The daemon and event bus (priority design)

Decision: **design the daemon and event bus first; the proxy engine is a
pluggable backend chosen later.** Everything in this section is deliberately
engine-agnostic.

## Why a daemon at all

Reticle today is a **one-shot CLI**: each command does forward → probe → act →
exit. But three of the new requirements are inherently *long-lived and
streaming*:

- the capture proxy is a persistent MITM listener;
- the action path is a time-ordered sequence accumulated across many commands;
- the web panel needs something to push live updates to a browser.

So we introduce one new run mode that owns all long-lived state:

```
reticle serve [--target android] [--session <name>]
   # long-lived daemon: runs the proxy, aggregates an event timeline,
   # serves the web panel on localhost, exposes a control + event API
```

The existing one-shot commands keep working standalone. When a daemon is
running, they additionally **publish their results as events** to it, so the web
timeline captures taps, snapshots, and screenshots alongside network traffic.

## The event bus — the core abstraction (engine-decoupled)

Everything observable becomes a typed event on a single in-process bus. Sources
publish; sinks consume. The proxy is merely *one source* — which is exactly what
lets the engine choice be deferred.

### Event envelope (uniform for every source)

```jsonc
{
  "id": "evt_01J...",          // monotonic, sortable
  "ts": 1719400000000,         // epoch millis (stamped by the daemon, not the script)
  "session": "sess_abc",       // ties device + app + time window together
  "target": "android:emulator-5554",
  "source": "proxy | action | ui | runtime | log",
  "type": "network.response",  // see taxonomy below
  "payload": { ... },          // type-specific, schema'd in reticle-protocol
  "refs": { "screenshot": "sess_abc/0007-after.png" }  // large blobs by path, not inlined
}
```

### Event taxonomy

| Source | Types | Payload (schema'd in `reticle-protocol`) |
| --- | --- | --- |
| `proxy` | `network.request`, `network.response`, `network.error` | method, url, status, headers, timing, body refs |
| `action` | `action.dispatched` | gesture (tap/swipe/drag/type), selector, resolved point, before/after node refs |
| `ui` | `ui.snapshot`, `ui.screenshot` | capture metadata + a `ref` to the on-disk artifact |
| `runtime` | `runtime.lifecycle` | agent started / injected / port bound / health change |
| `log` | `log` | app-authored bridge entries (existing `/logs`) |

The **normalized `NetworkEvent`** is the key decoupling point: whatever engine
produces it (see below), it adapts to this one type. The bus never sees engine
internals.

### Buffering, persistence, retention

- In-memory **bounded ring buffer** per session (default ~500 events,
  configurable). Large bodies/screenshots spill to a session dir, referenced by
  `refs`, never inlined into the event.
- Optional **JSONL persistence** to `~/.reticle/sessions/<session>/events.jsonl`
  so a run can be replayed into the panel after the fact — a persisted session
  dir generalizes a per-action trace dir into a full timeline.

### Sessions

A **session** ties a device + app + time window into one timeline, so the panel
can show "this run: these network calls + these taps + these screenshots" as a
single coherent view. One-shot commands attach to the active session if a daemon
is up (discovered via a pidfile + port under `~/.reticle/`), else they run
stateless as today.

## Web push transport (dependency-light)

Matching the hand-rolled-HTTP-server philosophy (no heavy framework):

- **Control + history**: plain HTTP REST on the daemon's localhost port
  (`GET /sessions`, `GET /sessions/{id}/events?since=`, `POST /act`, ...).
- **Live feed**: **Server-Sent Events** (`GET /events/stream`) — one-way
  server→browser, trivial to implement over the existing socket server, and
  sufficient for a live timeline. Reserve WebSocket only if the panel later needs
  rich bidirectional control; start with SSE + REST.

## Proxy backend behind an interface (engine deferred)

The engine is one `EventSource` that emits normalized `network.*` events:

```
interface ProxyBackend {
  fun start(listenPort: Int, ca: CaMaterial): Flow<NetworkEvent>
  fun stop()
}
```

Any of these can implement it later without touching the bus or the panel: an
embedded JVM engine (netty/LittleProxy-class), a managed `whistle` sidecar, or an
external `mitmproxy`. **The decision is deferred precisely because the event bus
makes it pluggable.** Design the bus and timeline now; pick the engine when the
proxy phase starts.

## Capture proxy — honest capability boundary

Decision: **pure host proxy only (L1). The agent does NOT touch the app's trust
chain or pinning — the no-hook line holds.** This deliberately equals whistle's
ceiling and must be documented as such:

- **HTTP plaintext** — captured freely.
- **HTTPS** — requires the device/app to trust our proxy CA. On Android 7+ apps
  do **not** trust user CAs by default: works for a **debuggable** app (via its
  `network_security_config`, or an app that explicitly opts in); system-wide CA
  trust needs **root** (out of scope). Configuring the device proxy itself via
  `adb settings put global http_proxy` is a **host** action (not a hook) and is
  in scope.
- **Certificate pinning** — defeats the proxy. whistle can't beat it either; we
  report the limit rather than crossing the no-hook line to bypass it.

(An "L2 agent-assisted" mode — injecting CA trust / neutralizing pinning at
runtime in a debuggable app — was considered and **rejected** to preserve the
no-hook guarantee. Recorded here so the trade-off isn't silently re-litigated.)

---

# WebView / DOM support

Decision: **mirror the Compose bridge — a default-on, read-only DOM bridge whose
nodes merge into the one unified tree.**

## It is structurally the same problem as Compose

The capture already handles a foreign tree hidden inside a native `View`:
`SnapshotCapture.captureView()` walks the native children, then calls
`ComposeSemanticsBridge.captureInto()` to merge the Compose **semantics** tree
into the same `nodes` map, tagged `NodeKind.composeSemantics`.

A `android.webkit.WebView` is the same shape: today it is an opaque leaf `view`
node; inside it hangs a **DOM tree** Reticle can't see. The fix is a second
bridge with the identical contract, not a new mechanism:

```kotlin
// in captureView(), right after the Compose merge:
val webChildren = WebViewBridge.captureInto(view, parentRef = ref, nodes = nodes) { makeRef() }
childRefs.addAll(webChildren)
```

A new `NodeKind.domNode` is added; DOM elements merge in as children of the
WebView node. Because `ui compact` / `ui tree` / `SelectorResolver` / `act tap`
all operate on `Node` and don't care whether a node came from a View, Compose, or
the DOM, **they reuse unchanged** — the dividend of the flat ref→Node model.

## Two things Compose doesn't have

1. **Async + cross-boundary read.** Compose semantics read synchronously by
   reflection on the main thread. The DOM is only reachable via
   `WebView.evaluateJavascript(js) { result -> ... }`, whose result is
   **asynchronous**. `captureLocked()` is synchronous (a `CountDownLatch` via
   `runOnMainSync`), so the bridge injects a read-only DOM-walk script and
   latches the JSON result back with a bounded timeout. Cost is real but bounded.
2. **Coordinate conversion.** The DOM reports **CSS pixels relative to the
   WebView viewport**; the whole tree is in **screen physical pixels**. Each DOM
   rect must be folded to screen space:
   `screen = webview.locationOnScreen + domRect × density − scrollOffset`. This
   is the most error-prone part (a wrong fold makes `act tap` miss), so the
   protocol contract pins it: **a `domNode.frame` is already in the screen
   coordinate system**, exactly like Compose `boundsInScreen`.

## Capability tiers (honest degrade, like `ui screenshot`)

| Tier | Mechanism | Yields | Precondition |
| --- | --- | --- | --- |
| **L0** (always) | current behavior | WebView as an opaque leaf node: frame, tappable as a whole | none |
| **L1** (DOM structure) | inject read-only DOM-walk JS, fold coordinates | DOM element tree: tag / id / class / text / screen rect; target by CSS selector or text; tap | WebView has JS enabled |
| **L2** (semantic) | JS reads ARIA role / accessible name | role + accessible name, aligned with the semantic tree | JS enabled |

L0 needs no work. L1 is the bulk. L2 is additive. The DOM bridge is **default-on
but read-only** — it injects a traversal script that does not mutate page state.
When JS is disabled or injection fails, Reticle does **not** fabricate a DOM: it
honestly leaves the WebView as an opaque L0 leaf, the same honesty rule the
Compose bridge follows for non-`AndroidComposeView` hosts.

## Scope

- **In scope:** app-embedded `android.webkit.WebView` (the hybrid-app case).
- **Out of scope:** Chrome Custom Tabs / Trusted Web Activity — they run in a
  *separate* (Chrome) process the in-process agent can't reach. Stated so it
  isn't mistaken for a gap.
- **Cross-platform reuse:** the `domNode` node kind and the "DOM rect folded to
  screen space" contract go into `reticle-protocol` as another platform-neutral
  node type — the same "inject JS, read DOM" approach maps directly to iOS
  `WKWebView` and the HarmonyOS Web component. This rides the protocol-is-the-
  spine principle above.

---

# Roadmap phases

Android first and complete; everything else reserved behind the spec + SPI.

### Phase 0 — Thin reservation (now, near-zero cost)
- **Rename now**: move `:reticle-agent` → `:reticle-agent:android` (grouping dir,
  no root `build.gradle`; set `archivesName` so the AAR stays `reticle-agent-
  android.aar`). Update the couplings this touches — `settings.gradle.kts`,
  `ci.yml`, `release.yml` (incl. the `reticle-agent.aar` / `…-payload.jar` asset
  names + launcher), `bin/reticle`, `validate_plugin.py`, `sample-app` dependency.
- Add `reticle-protocol/` with **authoritative JSON Schema (2020-12)** + golden
  fixtures; wire a CI contract test that validates `reticle-core`'s emitted JSON
  against it. Kotlin types stay hand-written.
- Introduce the `Platform` SPI; move `Adb` / `Injector` / `InputBackend` into
  `dev.reticle.cli.platform.android` behind it. **No iOS/HarmonyOS stubs.**
- **Design the daemon + event bus** (this document) — model, envelope, session,
  SSE/REST surface — decoupled from any proxy engine.

### Phase 1 — Android feature completion (pure additive, no new arch)
- **Live object inspection** + **layout diagnostics**, generalizing the existing
  reflection used by `mutate` — runtime class metadata, an `ui audit`, and
  constraint inspection via Java/Kotlin reflection.
- **Honest ceiling, documented:** class/field/property metadata + the
  *reachable* object graph (from view tree, singletons, static roots). **Not**
  heap instance enumeration, **not** arbitrary address reads — this is a
  structural limit, not an Android one. For a full heap, the honest path is
  host-side `adb shell am dumpheap` (debuggable app, no root) analyzed offline.
- **Action traces** — the first evidence package is in place via
  `act --trace-output`: `trace.json` records gesture, selector, resolved
  point/source/ref, and a compact snapshot diff, with before/after snapshots and
  screenshots stored beside it. `reticle serve` ingests these traces into the
  session event bus and renders them in the panel timeline.
- **WebView / DOM support** — `WebViewBridge` mirroring the Compose bridge,
  L0→L1→L2 tiers, DOM nodes merged into the unified tree (`NodeKind.domNode`).
  See the WebView section above. L1 read-only DOM walk + coordinate fold is
  landed for app-embedded `android.webkit.WebView`; remaining work is L2
  semantic enrichment and deeper fixture coverage for edge cases.
- **Thin-client sink-down** — `ui report` now consumes the agent's single-capture
  `/report` bundle, so `SemanticTree.build` / `CompactObservation.from` for
  report artifacts happen inside the app process. Remaining work: move selector
  resolution for actions to the agent so the CLI consumes finished targeting JSON.
  Keep `PortMap` on both ends as a protocol rule. This is the real "make the CLI
  clean" work surfaced by the language question — it makes the CLI language-free
  and tightens single-capture consistency. See "CLI is a thin client" above.
- **Agent-facing targeting + batch (landed, 0.6.5–0.7.0)** — `ui outline --live`
  numbers visible targets and caches short-lived `@N` aliases; `act --alias`
  taps them; selector misses report same-kind candidates from the current
  snapshot. `act batch` sequences a deterministic flow from a JSON file, stopping
  on first failure. `Reticle.registerProbe(testId, metadata)` lets a linked app
  register a synthetic addressable node for a spot with no convenient concrete
  view (canvas region, off-screen state). These keep the deterministic-selector
  backbone while lowering the cost of agent-driven targeting — they are *not* a
  screenshot/NL-exploration path.

### Phase 2 — Proxy + daemon
- Done: `reticle serve`, the event store, session model, SSE/REST surface,
  action-trace ingestion, pure-host HTTP proxy, device auto-proxy config, CA
  issuance, opt-in HTTPS MITM, and session-scoped network mocks.
- Done (0.7.x follow-ups): **streaming upstream forwarding** — responses are
  forwarded chunk-by-chunk (identity under `Content-Length`, decoded/unknown
  under chunked) with client-driven back-pressure and a bounded stored-artifact
  prefix, so a large body no longer buffers whole in the daemon; **typed
  `network.*` schema** (`reticle-protocol/schema/network-event-payload.schema.json`)
  plus request/response/error golden fixtures, validated by a Kotlin contract
  test and pinned to the Swift emitter by a Swift field-set test; and **richer
  mock matching** — `regex` match (validated at upsert, tried against path and
  full URL), `ANY` method wildcard, and query `"*"` presence predicates, all in
  `NetworkMockStore` with mock state still decoupled from the event store.
- Next: expand typed schema coverage to the remaining event families (action /
  runtime payloads) and add matcher predicates for headers/body when a concrete
  use case appears.

### Phase 3 — Web panel
- Done: a localhost read-only evidence panel showing action traces,
  screenshots/artifacts, network lane cards, body previews, MITM/tunnel/mock
  mode, and mock rule/value ids.
- Done (0.7.x follow-ups): **network filters** — mode (MOCK/ERROR/MITM/TUNNEL),
  status class (2xx/3xx/4xx/5xx), and a free-text search over
  method/url/host/path/status/mock ids, all composable; a **Mock groups** view
  toggle that groups mocked requests under their rule (with hit counts) and the
  rest by host; and a **copy as mock** chip on each network card that assembles a
  ready-to-run `reticle mock set` command (including `--body-file` for the
  captured response) to the clipboard. The panel stays display-only — it emits a
  command for the user to run, it does not POST mock state itself.
- Next: revisit reverse-drive only if the deferred question below is answered
  (would force a bidirectional transport); otherwise the panel boundary holds.

### Phase 4 — Multi-platform
- iOS / HarmonyOS agents in their own build systems, conforming to the protocol
  spec. The host and panel are reused; each new platform supplies its three seams
  — natively in the host where the ecosystem matches (iOS: simctl/DYLD in a Swift
  host) or as a helper where it doesn't (Android: the Kotlin `reticle-android-
  helper`). See "Direction: Swift host + per-platform helpers".

# Proposed next: evidence workflows + security-evidence lane

Not yet built. Everything below is a **productization layer on top of primitives
that already exist** (action traces, screenshots, network events, node rects, the
session timeline) — it adds no new capture mechanism and does not move the
defining line. Three constraints hold verbatim across every item here:

1. **Evidence, not verdicts.** These workflows emit richer, more comparable
   evidence and difference magnitudes only. No `assert`/`verify` primitive; no
   pass/fail or risk grade is produced by Reticle — the agent or a human decides.
2. **Deterministic selectors stay the backbone.** No natural-language-target /
   guess-from-screenshot mechanism is promoted to the primary targeting path. The
   landed `ui outline --live` + `@N` aliases are the acceptable convenience layer;
   exploration is a coverage aid, never the verification path.
3. **No root / no repackage / no hook / no pinning bypass.** The security lane is
   a *defensive evidence engine*, not an attack or bypass tool.

## Workstream A — evidence-workflow products

Each assembles existing primitives into a product a human can consume directly.

- **A1 — PR evidence bot (`reticle review`).** A CI/PR wrapper: read the diff →
  drive a deterministic flow to the affected screens → assemble action trace +
  before/after compact diff + network events + screenshots into a PR comment.
  Reuses `act batch`, `act --trace-output`, the session timeline, and the panel's
  evidence-ranking logic. Posts evidence only; the human makes the call. *Builds
  on Phase 1 traces; CI/GitHub integration lands with Phase 3.*
- **A2 — visual regression (`reticle diff visual`).** Pixel-diff screenshots
  between two builds (or before/after one build) with a configurable threshold and
  a change-region overlay report. Complements the existing structural diff:
  structural diff answers "text/state changed", pixel diff answers "layout/render
  drifted". The threshold is a hint, not a verdict. *Report first (Phase 1),
  panel card later (Phase 3).*
- **A3 — design-fidelity evidence (`reticle diff design`).** Align a design
  frame's component boxes with the live node rects (`ui report` / `ui regions` /
  `ui node`) and emit per-region deltas (position / size / color / text) plus an
  overlay. Design data comes through the existing Figma channel. Emit the delta
  magnitudes, **not a letter grade** — grading is a verdict left to the consumer.
  Reticle only measures the geometric/style delta against a given frame; it does
  not judge whether the design is correct. *Phase 1 evidence; panel Phase 3.*
- **A4 — flow replay artifact (`reticle replay gif`).** Stitch a flow's per-step
  screenshots into a device-framed GIF/MP4 for human review and PR communication;
  step captions come from the trace's gesture/selector. Lowest cost, highest
  review leverage — do first. *Phase 1.*
- **A5 — navigation / coverage map (`reticle map`, scoped carefully).** Fold
  `ui outline` + action-trace screen transitions into a "screen → reachable path"
  map, **positioned as a coverage aid** ("which screens/paths are not yet covered
  by an E2E flow"), never an auto-verification path. Discovery only; verify with
  deterministic-selector flows afterward. *After Phase 1; lower priority.*

## Workstream B — security-evidence lane (Reticle's own scope)

Security is a first-class direction, but its scope must be drawn precisely.
In a security context Reticle is a **defensive evidence engine**: it observes,
drives, and captures security-relevant evidence for review — it does not hook,
bypass pinning, or inject.

**Out of scope (crosses the no-hook line — Frida/root territory):** certificate
pinning *bypass* / runtime CA-trust injection / pinning neutralization; hooking
the capture pipeline or virtual-camera / deepfake injection (PAD/IAD red-team);
reversing or cracking the binary itself.

**In scope (all within observe/drive/capture + reflectable metadata + host proxy):**

- **B1 — sensitive-data-in-transit evidence.** On the existing host proxy/MITM
  lane, observe and annotate how sensitive data moves and emit evidence (not a
  "vulnerable" verdict): plaintext-HTTP transmission flags; annotated positions of
  suspected sensitive fields (configurable patterns) in request/response bodies;
  and an honest "opaque, not decrypted" annotation when an HTTPS CONNECT tunnel
  can't be decrypted. Reuses `network.*` events and the panel's existing
  cookie/authorization redaction. When pinning blocks capture, it reports
  "not observable" rather than crossing the line to defeat it. *Phase 2 (additive
  on the proxy).*
- **B2 — risk-control flow E2E regression harness (highest fit, do first in B).**
  Use deterministic-selector drive as a regression harness for the risk-control
  features themselves: drive liveness / 1:1 face-upload / device-check UI flows,
  capture their calls to external verification/attestation services, and use
  session-scoped `mock` to simulate different external verdicts (trusted /
  untrusted / degraded) so the client's per-branch UI and follow-up calls can be
  verified deterministically. Reticle only *drives the real flow + mocks the
  external return + records evidence*; it does not fabricate captured content or
  attack the liveness check (that is red-team, not here). *Phase 2 (needs mock +
  proxy).*
- **B3 — client security-posture evidence (observe-only).** Emit a read-only
  snapshot of security-relevant client configuration, entirely within the
  reflectable-metadata and host-observable boundary: whether the app is
  debuggable; user-CA-trust / network-security-config annotations; whether the
  WebView has JS enabled and whether mixed content is present (from the existing
  WebView/DOM bridge); and the component-exposure surface visible through
  class/field metadata reflection (built on the Phase 1 live-object-inspection /
  `ui audit` capability, viewed through a security lens). Lists observable facts
  only — no heap enumeration, no arbitrary reads, no "insecure" verdict. *After
  the Phase 1 object/layout diagnostics land.*

## Suggested sequencing

Do **A4 + A1 + A2** first — they reuse existing traces/screenshots with near-zero
new mechanism and directly raise human-review and PR-evidence quality. On the
security lane, do **B2** first — it fits Reticle's deterministic-drive + mock
shape best and carries the most value. A3 / B1 / B3 follow; A5 is lowest priority.

## Honest boundaries (carry into every doc and the skill)

- **No root, no repackage, no byte-code hooking** remains the defining line.
- **Object/heap inspection**: reflectable metadata + reachable graph only; heap
  enumeration is out (use `am dumpheap` offline).
- **Network capture**: host MITM equal to whistle; HTTPS needs CA trust; pinning
  is not bypassed.
- **WebView / DOM**: read-only DOM via injected traversal JS; needs JS enabled in
  the WebView; falls back honestly to an opaque leaf when unavailable. Custom
  Tabs / TWA (separate process) are out of scope.
- **Injection**: linked agent or JDWP into *debuggable* apps; non-debuggable
  release builds and arbitrary real-device apps are out of scope (Frida/root
  territory we don't enter). iOS real-device, when it comes, will require the app
  to link the framework at build time.

## Deferred / open questions

Explicitly parked — not yet decided, recorded so they aren't forgotten or
mistaken for settled. Revisit when the trigger arrives.

- **HarmonyOS feasibility probe.** The HarmonyOS rows in the platform-seams table
  (`hdc`, injection, input) are paper placeholders with **zero validation** —
  whether `hdc` has equivalents for `forward` / `input` / a debug-injection
  channel is unverified. Deferred. *Trigger:* before HarmonyOS appears in any
  committed plan (i.e. before Phase 4 touches it), spend a short spike to confirm
  the seams exist; until then it stays marked `est.`/`TBD`, not promised.
- **Web panel reverse-drive.** The Phase 3 panel is **display-only** for now
  (traffic + action path + screenshots over one-way SSE). Whether the browser can
  *drive* the app (click in the panel → trigger `act tap`) is open. *Trigger:* if
  reverse-drive is wanted, it forces a bidirectional transport (WebSocket over
  the current SSE) plus a meaningful chunk of front-end interaction work — decide
  before committing the Phase 3 transport so SSE-vs-WebSocket isn't reworked.
- **Host language: Swift host + Kotlin Android helper — DONE (shipped, no longer
  deferred).** The chosen shape has been executed and ships today: the host
  program (CLI + daemon + Web) is Swift (`reticle-host`, SwiftPM), the entire
  current Android layer stays Kotlin as the long-lived `reticle-helper` invoked
  over an RPC contract, and JDWP is *not* rewritten. `bin/reticle` runs the Swift
  host + native helper as the default; there is no user-facing Kotlin/JVM CLI
  anymore. The three open sub-questions are all resolved: the helper RPC contract
  is in `reticle-protocol/helper-rpc.md`; the Kotlin helper ships as its own
  **GraalVM native-image** (no-JDK single-file `reticle-helper`), not a JVM jar;
  and the two resident processes are supervised via the `reticle serve`
  helper-broker (0.6.5), which keeps one helper alive behind the daemon and routes
  `--use-daemon` / `RETICLE_USE_DAEMON=1` command RPC through it. See "Direction:
  Swift host + per-platform helpers" and "Status (2026-06-26): a working Swift host
  CLI exists" above — this item is retained here only as a pointer; it is no longer
  an open question.
