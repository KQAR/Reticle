# Reticle Architecture

Reticle inspects the app that is actually running and drives real input. It
rests on three mechanisms: getting observation code into the target process,
talking to it over a loopback channel, and synthesizing real input from the
host. This document describes each, then the UI-tree model, selectors, and the
multi-region detection that targets a specific phrase inside a single View.

Three diagrams carry the shape of it, and everything else here is commentary on
them: the two processes and the Android/iOS split (below), the one capture and the
projections derived from it (**Two trees**), and the channels style is read through
(**Style evidence**).

An interactive version of those diagrams, plus a machine-readable form of the same
model for agents, lives in **[architecture-map/](architecture-map/)** — click a
module for its edges, or pick a flow (`ui report`, `app inject`, selector
resolution, the network lane, …) and step through it. It is a *projection over this
document*: if the two disagree, this one wins and the map is stale.

## The shape of the system

Two processes on two machines, and one asymmetry that is worth seeing before
reading any of the prose: **Android device work goes out through a separate
native helper; iOS device work happens inside the host itself.**

```
┌─ host (macOS 14+ arm64) ─────────────────────────────────────────────────┐
│                                                                          │
│  reticle — the one user-facing binary        --target android | ios      │
│     │                                                                    │
│     │  HostBackend: one typed method per capability, not stringly RPC    │
│     ├──────────────────────────────┐                                     │
│     ▼                              ▼                                     │
│  AndroidBackend                 ReticleHostIos                           │
│  the ONE place the helper's     iOS has NO helper: simctl / devicectl,   │
│  JSONL method names are         loopback HTTP, CoreSimulator HID, and    │
│  spelled                        its own wait / scroll-to / verify loops  │
│     │                              │                                     │
│     ▼                              │                                     │
│  reticle-helper (GraalVM native, no JDK on the user's machine)           │
│  adb · JDWP injector · input backend · selector resolution               │
│     │                              │                                     │
│  ┌──┴──────────────────────────────┴────────────────────────────────┐    │
│  │ reticle serve — host-owned; the agent owns no session state      │    │
│  │ events.jsonl · SSE · read-only panel · ReticleNetworkLane        │──▶ device
│  │ (Loom capture engine + traffic rules + flow replay)              │    traffic
│  └──────────────────────────────────────────────────────────────────┘    │
│                                                                          │
└─────┼──────────────────────────────┼─────────────────────────────────────┘
      │ adb forward tcp:<port>       │ loopback HTTP
      │ adb shell input tap|swipe    │ CoreSimulator HID (simulator only)
      ▼                              ▼
┌─ inside the app's OWN process (device / simulator) ──────────────────────┐
│                                                                          │
│  ReticleServer, bound to 127.0.0.1:PortMap.derivePort(applicationId)     │
│    GET /snapshot /semantics /compact /screenshot /logs · POST /mutate …  │
│                                                                          │
│  got there by: a linked AAR ContentProvider · a JDWP payload dex · a     │
│  DYLD constructor (iOS injection) · a plain Reticle.start()              │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

Four things this picture is meant to settle:

- **The agent observes; it never synthesizes input.** Taps and text come down the
  left-hand path from the host. The only reason the agent touches input at all is
  the clipboard staging for non-ASCII text (mechanism 3), which Android only
  permits from inside the foreground app.
- **The port is derived, not fixed.** `PortMap.derivePort(applicationId)` is shared
  verbatim by agent and host, so two linked apps never collide — and changing that
  hash desynchronizes both sides at once.
- **`reticle serve` is host-owned state.** The agent and helper supply device
  operations and runtime observations; session events, artifacts, traffic rules and
  the panel never live on the device.
- **The helper is not a CLI.** Its only entry points are `helper` (the JSONL RPC
  server the Swift host spawns), `version` and `help`. Users never invoke it.

## The three mechanisms

### 1. Getting observation code into the target process

Reticle's in-process server has to be running inside the app. There is no
general way to inject arbitrary code into any Android process, so there are
three options, in order of practicality:

| Mode | Mechanism | Works on |
| --- | --- | --- |
| **Linked** (default) | Add the `reticle-agent` AAR; a no-op `ContentProvider` (`ReticleInitProvider`) auto-starts the server during process init — no app code changes | Any build you can add a dependency to |
| **JDWP injection** (`reticle app inject`) | Load a payload dex into the live process over the debugger channel and call `Bootstrap.start()` — no repackage, no root | Any **debuggable** APK (incl. release-signed user builds, where `wrap.<pkg>` is blocked) |
| **Frida / root** | `frida-server` or LSPosed injects into any process | Rooted device / emulator image, release (non-debuggable) APKs |

The `ContentProvider` trick is the same one androidx App Startup and Firebase
use to self-initialize: it is instantiated before `Application.onCreate` returns
control to UI, so the server is up before the first screen renders, with no app
code changes. The demo (`sample-app`) uses the **linked** mode.

#### JDWP injection (the unlinked path)

For a **debuggable** app you don't build (so you can't add the AAR), `reticle
app inject` gets the same runtime running with no repackage and no root. Every
debuggable process exposes a JDWP (Java Debug Wire Protocol) channel — even on a
locked `ro.debuggable=0` *user* build where `setprop wrap.<pkg>` is rejected by
the kernel — and JDWP can invoke methods in the live VM. The host CLI
(`Injector` + `Jdwp.kt`, pure `java.net`, no third-party JDWP lib):

1. **stages the payload dex** (`reticle-agent:android` + `reticle-core` + kotlin-stdlib +
   kotlinx-serialization, dexed by `d8` — see `:reticle-agent:android:dexPayload`) into
   the app's private `code_cache` via `adb push` to `/data/local/tmp` then
   `run-as <pkg> cp`. The staged dex is `chmod 0444` — **ART's W^X policy (API
   26+) refuses to load a dex writable by the loading uid**;
2. **`adb forward tcp:<h> jdwp:<pid>`** to reach the channel; handshake + IDSizes;
3. **arms a one-shot BREAKPOINT** at `android.os.Handler.dispatchMessage` (a
   single-method instrumentation, the chokepoint every main-looper message runs
   through) with `Count(1)` so it fires once and ART drops the instrumentation;
4. on the thread the breakpoint suspends, **invokes**
   `PathClassLoader(dexPath, getSystemClassLoader())` → `loadClass` →
   `Bootstrap.start()`, which calls `ReticleRuntime.start(ActivityThread
   .currentApplication())` — no ContentProvider needed.

The host then verifies over HTTP with the same `probe()`/`waitForRuntime()` gate
every other command uses; success is the server *answering*, not the invoke
returning.

Hard constraints, each learned on-device and encoded in the injector:

- **Never `METHOD_ENTRY` on a busy app.** It forces a whole-VM deoptimization and
  ANR-kills a heavy app. A single-method `BREAKPOINT` is scoped and safe.
- **Keep the suspended thread's work tiny.** The breakpoint suspends the *main*
  thread; long work there → ANR. So invoke with the "resume all other threads"
  option (not `INVOKE_SINGLE_THREADED`, which deadlocks against ART's dexopt/GC
  daemons), and use `PathClassLoader` (ART self-optimizes) rather than the legacy
  `DexClassLoader(…, optimizedDir, …)` ctor (NPEs on a null optimized dir).
- **Pin every `CreateString` with `DisableCollection`.** A JDWP-created string is
  held by no GC root; on a busy app it is collected before the next invoke and
  surfaces as JDWP error 20 (`INVALID_OBJECT`).
- **The target must already hold `INTERNET`.** The injected server opens a
  loopback socket; without the permission the bind fails `Permission denied`.
  Real apps have it; the `noagent` sample declares it to stay honest.

Authorized testing only — injecting into an app you don't own requires explicit
authorization. The bundled `sample-app` ships a `noagent` flavor (no AAR, no
runtime classes) as the honest test target for this path.

### 2. Talking to the running app

`ReticleServer` opens a raw `ServerSocket` bound to `127.0.0.1` inside the app —
a small hand-rolled HTTP server, no third-party dependency. The host CLI reaches
it through `adb forward tcp:<host> tcp:<device>`, since the host and device are
separate machines.

Endpoints (see `reticle-core/Protocol.kt`):

```
GET  /runtime        RuntimeInfo
GET  /snapshot       Snapshot (full view tree)
GET  /semantics      SemanticTree
GET  /compact        CompactObservation
GET  /logs           LogBatch (app-authored bridge)
GET  /screenshot     image/png
POST /mutate         MutationResult  (body: MutationRequest)
POST /clipboard      "ok"            (body: raw UTF-8 text; stages non-ASCII input)
```

### 3. Synthesizing real input

Input is dispatched from the host with `adb shell input tap|swipe|text|keyevent`
— public, documented, and stable. `drag` is a long-duration `swipe`.

**Non-ASCII text** is the one case `adb shell input text` can't handle: it
silently drops anything outside printable ASCII (CJK, accented Latin, emoji).
Host-side `adb shell cmd clipboard` is also unavailable on many OEM builds, and
Android 10+ only lets the *foreground app* write the clipboard. So `act type`
splits by content: ASCII goes straight through `input text` (works even on apps
without the agent), while non-ASCII is staged on the clipboard **by the
in-process agent** (`POST /clipboard` → `ClipboardManager.setPrimaryClip`, which
is allowed because the agent runs inside the foreground app) and then pasted
with `KEYCODE_PASTE`. The non-ASCII path therefore needs a reachable runtime and
a focused input field; the ASCII path does not.

When `act type` is given a targeting selector (`--test-id`, `--css`,
`--point`, …), the host taps the resolved field first and waits a short settle
so the text lands in *that* field rather than whatever happened to hold focus;
with no selector it types into the current focus. Either way the text is
inserted at the cursor — `type` never clears the field.

**The tap is not the guarantee, the focus reading is.** A resolved node that
cannot take focus — the outer container of a compound input widget, which is
routinely the only uniquely-addressable handle on a form row — swallows the tap
and leaves the text going wherever focus already was. So after the focusing tap
the host reads the tree back and classifies who holds focus relative to the
resolved node (`focusLanded=self|descendant|ancestor|elsewhere|none|unknown`,
from `Node.isFocused`), retargets once when the node contains exactly one
focusable input, and REFUSES to type when focus landed nowhere or somewhere
unrelated. `ancestor` is a pass: a WebView owns the platform focus while the
caret is in a DOM input, as does an `AndroidComposeView` for a Compose
`TextField`, and neither exposes a finer channel. `unknown` (no runtime, older
agent) is reported and never enforced. `Node.isFocusable` is the TOUCH reading
(`focusableInTouchMode`), because since API 26 `FOCUSABLE_AUTO` reports every
clickable container as focusable — the false positive that makes this shape look
fine.

**And the focus reading is not the guarantee either — the text is.** `chars=N`
counts the characters SENT. Measured on a physical device: `--text "10000"`
reported `chars=5`, exit code 0, focus correct, and the field held `100`, while
the field beside it took the same five characters intact. The difference is what
each field does per keystroke — the lossy one reformats in a `TextWatcher` and
re-renders a bound widget above it (101 changes in the trace against the other's
6), and `input text` delivers the string as a burst of key events that a
re-layout in the middle of can eat. So `type` reads the field back and reports
what it holds (`TypeReadback`): `textLanded=exact|reformatted|partial|none|
changed|unreadable`, plus `text=` and, for a partial landing, `landedChars=`.

The classification is evidence, not a verdict. `reformatted` (the app added
separators to everything it was given) and `changed` (the app rewrote its input —
uppercasing, masking, `maxLength`) are the app doing its job and are only
reported. `partial` and `none` are the burst-loss shape, and only those are
re-sent — once, over the clipboard, which a `TextWatcher` sees as a single change
rather than a run of keystrokes — and only when the field was EMPTY beforehand,
since `type` inserts at the caret and there is no way to undo a partial insertion
into existing content without guessing what the caller meant to keep. The result
says what happened (`recovery=`), never silently. `--type-delay <ms>` is the
caller's own escape hatch: one `input text` per character with that gap, for a
field known to lose the burst. A field with no text channel reads
`textLanded=unreadable` with a reason rather than passing by default.

**And an action can be answered where no snapshot can see it.** Measured on an
API 36 emulator, four channels at once while one text toast was on screen: the
app's view tree — absent; the agent's in-process screenshot — absent; device-level
`screencap` — present; `dumpsys notification`'s Toast Queue — **the text
verbatim**. On Android 11+ `Toast.makeText` does not draw in the app at all
(`INotificationManager.enqueueToast`, then the system draws it in a window of its
own), so a submit the backend rejected produced a byte-identical before/after pair
and read as `0 change(s)` — the documented signal for a gesture that hit nothing.

So every `act` watches the Toast Queue across the action (`ToastProbe`,
`ToastQueue`) and reports `toast=` / `toastKind=` / `toastDuration=`. Host-side
over `adb shell`, so it needs no agent and no hidden API. Samples ride along with
work the action was already doing, on a front-dense backoff, plus **one taken at
`stop`** — the important one, since resolving and settling a selector can eat the
whole front of the schedule before the touch is even synthesized, while at the end
the gesture has landed and the toast is 2s/3.5s into its life.

The three things called "a toast" are three different problems, and the fix must
not blur them: `Toast.setView` and any app-drawn overlay belong to the app's own
process and are **already** nodes carrying their text (measured), while a
custom-view toast's queue record carries a callback and no string. So the queue
and the tree each hold half, `toastKind` says which half, and an overlay is
reported as no toast at all because it is not one. What stays unreachable is a
toast raised by ANOTHER process — filtered out by package, since attributing the
system's "Screenshot saved" to the app under test would be a wrong claim.

The one gap is multi-touch `pinch`, which `input` can't express — it would need
`sendevent` against the touchscreen device node. The API shape is reserved
(`InputBackend.pinch()`) but not implemented.

## Host-side daemon, network lane, and traffic rules

`reticle serve` is the host-owned long-lived surface. It creates an
`EventStore` under `~/.reticle/sessions/<session>/`, starts a localhost
Hummingbird server, and optionally starts the host proxy. The Android agent and
helper do not own daemon state; they only supply device operations and app
runtime observations.

The daemon exposes three route groups:

- session routes: health, current/historical events, action trace ingestion, and
  artifact reads through event refs;
- rule routes: current-session traffic-rule / mock-value management, plus flow
  replay (`POST /sessions/current/flows/:id/replay`);
- stream routes: the read-only panel and SSE event stream.

Network capture runs on Loom's engine (see the network lane above); Reticle
normalizes its flows into `network.request` / `network.response` / `network.error`
events, and the frames inside an upgraded WebSocket into `network.websocket`
events under the same `requestId`. Frames are emitted as they arrive rather than
summarized at close, because a socket may outlive the session; a response event
also carries `ttfbMs` / `receiveMs`, splitting a slow call into server think-time
and transfer time. HTTPS traffic is visible as CONNECT tunnels unless `--proxy-mitm` and
`--proxy-ssl-hosts` admit the host and the app trusts Reticle's local CA. MITM
still does not bypass certificate pinning or custom trust managers.

Traffic rules are also host-side. `NetworkRuleStore` persists rule metadata,
value metadata, and response body files separately inside the session directory.
A rule's `actions.route` is one of `mock` / `block` / `mapRemote` / `passthrough`,
with orthogonal modifiers (`delayMs`, header rewrites, find/replace substitutions);
these translate 1:1 onto Loom's `RuleActions` in `LoomCaptureLane`. When a rule
acts, the captured response event carries `ruleApplied`, `ruleId`, `ruleAction`,
and (for a mock route) `mockValueId`. If a mock rule points at a missing value,
Reticle records `network.error` and returns 502 rather than silently falling
through. A rule the engine rejects at sync time (Loom validates each one and
applies the rest, rather than failing the whole set) is named on stderr as NOT
active — an agent that adds a mock and gets no error must not then be surprised by
live traffic. Rules can optionally narrow by host wildcard and query key/value
predicates; value bodies can be imported/exported as base64 while remaining
stored as separate body files on disk.

Transport is Loom's, not Reticle's: the SwiftNIO proxy, HTTPS MITM (per-host leaf
certs off an on-demand CA), and upstream forwarding all live inside Loom's
`ProxyEngine`, consumed as the `LoomProxyCore` / `LoomSharedModels` SPM library.
`LoomCaptureLane` runs the engine with `persistFlows: false` (Reticle owns storage),
subscribes to `flowStream()`, and normalizes each exchange into a `network.*`
event — so a slow or failing upstream is Loom's concern, and Reticle only sees
completed/errored flows.

The whole lane — `LoomCaptureLane`, `NetworkRuleStore`, `NetworkBodyStore`, the
event models, and the replay path — lives in its own `ReticleNetworkLane` SwiftPM
target, not in `ReticleHostCore`. It depends only on `ReticleHostShared` (the
dependency-free `JSONValue` / event models / `HelperError` layer) and Loom's
`LoomProxyCore` / `LoomSharedModels` (no SwiftNIO of its own), and reaches the
session store through a single `NetworkEventSink` protocol (`emit` +
`sessionDirectory`) rather than referencing `EventStore` directly. `EventStore`
conforms to that sink in `ReticleHostCore`, and the Hummingbird rule/flow routes and
the `reticle rule` / `reticle replay flow` CLIs are thin adapters over the lane's
public API. This is the compiler-enforced realization of the "capture engine behind
one sink" decision (docs/roadmap.md): the lane builds and tests without the daemon,
and swapping the engine means editing one target, not untangling it from the host. Its
end-to-end path (serve → proxy → mock → `events.jsonl`, including a MITM'd HTTPS
hit) is guarded on real sockets by `scripts/e2e-proxy.sh` in CI.

## The declarative-UI boundary: Compose

Reticle's rule for Jetpack Compose:

> Reticle does not synthesize a Compose view tree. Composables are valid
> movement/input targets only when they are exposed through the semantics tree.

There is no classic `View` per composable. Reticle reads the **SemanticsNode
tree** (the same tree that backs accessibility and `Modifier.testTag`)
reflectively in `ComposeSemanticsBridge`, with no hard Compose dependency
(`compileOnly`). If the Compose runtime shape changes or the host view isn't an
`AndroidComposeView`, Reticle emits nothing rather than inventing selectors from
private internals.

## The declarative-UI boundary: SwiftUI (iOS)

The iOS analogue of the Compose rule above. Reticle does **not** synthesize a
SwiftUI view tree or invent selectors from SwiftUI's private backing views
(`_UIGraphicsView`, `CGDrawingView`, …). A SwiftUI element is a valid
movement/input target only when it is exposed through the platform
**accessibility** tree — the hosting view's `accessibilityElements` (read in one
pass via the private `_accessibilityElements` accessor to stay O(N) on large
hosting containers, with a guard for `CGDrawingView` returning `NSNotFound` from
`accessibilityElementCount()`). Each such element becomes a `NodeKind.axElement`
node. A SwiftUI element with no `.accessibilityIdentifier()` is therefore not
addressable — this is a documented contract, not a bug. An optional, default-off
`Mirror`-based reflection of a user `View`'s scalar `@State` (env
`RETICLE_SWIFTUI_REFLECT=1`) is surfaced as evidence-tagged metadata, never as a
selector.

**Links inside one `Text` are sub-regions of that element**, the same shape the
Compose bridge handles on Android. A markdown `Text` ("Read the \[Terms]\(…) and
\[Privacy]\(…)") is ONE accessibility element with one label: no `UILabel`, no
`NSAttributedString.link` run, no child element, and no view to measure, so every
`RegionProbe` channel comes up empty. The one surface that does exist — measured,
after the alternatives (child elements, element count, custom actions, custom
rotors, `_accessibility*` link accessors) all returned nothing — is
`accessibilityAttributedLabel`, which splits the label into runs carrying
`UIAccessibilityTokenLink` on the link ranges plus per-run font tokens. Those are
system-emitted attributes on a public property, not SwiftUI internals.
`SwiftUITextRegions` re-lays those runs out with their own fonts inside the
element's screen frame (the `TextLayoutStack` reconstruction, anchored to a screen
rect instead of a view) and emits per-link `span` regions plus a char grid.
Geometry is therefore **reconstructed, not read** — pinned end to end by the iOS
suite, which taps each recovered rect and checks which URL the app's `openURL`
handler actually received.

## The embedded-Web boundary: WebView DOM

An `android.webkit.WebView` remains a real View node, but Reticle now also reads
its visible DOM through a default-on, read-only bridge when JavaScript is enabled.
`WebViewBridge` runs a traversal script with `evaluateJavascript`, folds DOM
rectangles into screen coordinates, and appends each element as a `NodeKind.domNode`
child under the WebView. The script does not mutate page state.

**The script itself is one file, embedded twice.** Both bridges — Android's and the
WKWebView twin — run the same JavaScript, and it used to be hand-copied between the
two agents under a `KEEP IN SYNC` comment: with Kotlin raw strings escaping one way
and Swift multiline literals another, the two copies could not even be compared with
a diff, so nothing failed when one moved. The traversal now lives once in
`reticle-protocol/scripts/dom-traversal.js` and is embedded verbatim in
`dev.reticle.core.WebViewDomScript` and `ReticleProtocol.WebViewDomScript`, each
asserted equal to that file by its own suite. Embedded rather than loaded from a
resource because the Android agent also ships as a payload dex that `app inject`
pushes into a live process, and a dex carries no resources — so a resource read would
work in the linked build and fail exactly on the unlinked path.

If JavaScript is disabled, the WebView is detached, the callback times out, or
the result cannot be parsed, Reticle emits no DOM nodes and leaves the WebView as
an opaque L0 leaf. CSS targeting is host-side: DOM nodes carry a `domCssSelector`
metadata field, and `act tap --css '#web-pay'` resolves that snapshot node to a
real adb tap point.

**Third-party kernels (X5/TBS, UC) are a boundary, deliberately not an adapter.**
`WebViewBridge` is typed on `android.webkit.WebView`; a kernel that only *calls*
itself a WebView cannot be attached to, so such a view has no DOM at any level —
structurally, not transiently. A reflective adapter was considered and **rejected**:
it could not be verified without a real kernel sample, and an unverifiable bridge
that silently returns nothing is worse than a stated boundary. What Reticle does
instead is refuse to look like an empty page — `SnapshotCapture` marks a view whose
class says WebView but is not the platform one (and which wraps no real WebView)
with `custom["domStatus"] = "unsupportedKernel"` plus `custom["domKernel"]` naming
the class, compact renders `dom:unsupported-kernel`, and a `--css` miss on that
screen explains why no selector can ever match. The test is the shape, not a vendor
list, so it needs no maintenance as kernels come and go; "suspected" is the honest
word, which is why the class name travels with the claim. iOS has one web engine,
so this cannot arise there.

## Two trees, and which command uses which

One capture, four sources, then several projections over it — and every
projection is a pure function of the same `Snapshot`, which is why no two of them
can describe different frames:

```
   in the app's process                          on the host (pure derivations)
   ────────────────────                          ──────────────────────────────
   View / UIView tree ──┐
                        │                       ┌─ SemanticTree ······· act (movement/input:
   Compose semantics ───┤                       │                       semantic first)
   (reflective, a11y-   │                       │
    backed only)        ├──▶  Snapshot  ──▶─────┼─ CompactObservation ·· ui compact  (what an
                        │     ONE frame,        │                        agent gets by default)
   WebView DOM ─────────┤     ONE ref space     │
   (injected JS)        │                       ├─ StyleObservation ···· ui style
                        │                       │
   app-authored probes ─┘                       └─ the raw nodes ······· ui tree · ui node ·
                                                                         mutate · act (fallback)
```

Three rules hold this together. **Refs are shared**: a `ref` from any projection
re-resolves to the same node — and on Android to the same live `View`, since
`viewByRef` replays the identical walk with the identical numbering. So a style
finding can be tapped, and a tapped node can be inspected, without a second
capture. And **each derivation exists exactly twice** — Kotlin in `reticle-core`,
Swift in `ReticleProtocol` — because the Android helper and the iOS host are
different binaries. Twins are pinned by shared fixtures under
`reticle-protocol/fixtures/`, which is the only thing stopping them from slowly
answering differently; `CompactObservation` drifted that way before the fixtures
existed.

And **the rendering is part of the projection, not part of the host.** A shared
derivation whose text formatting lives in each host separately has only half a
contract — the two can agree on every field and still print one screen two ways,
which is precisely how `compact` drifted. So `Render` (`compact` / `tree` /
`semantics` / `regions`) sits in `reticle-core` and in `ReticleProtocol` beside the
derivations, both pinned by
`reticle-protocol/fixtures/snapshot-render.cases.json`; the hosts only call it. What
stays host-side is what genuinely is: fetching or loading the snapshot, window
scoping, `ui node` (which renders through selector diagnostics), and the Android-only
`@N` alias cache — the one projection with no Swift twin, and named as such in
`Render.swift` rather than left to be discovered.

Reticle maintains **two separate trees** from a single capture. Confusing them
is the most common mistake when reading the output, so this is explicit:

| Tree | Node type | Built by | What it contains |
| --- | --- | --- | --- |
| **View tree** | `Node` (`Snapshot.nodes`) | `SnapshotCapture` walking `WindowManagerGlobal` roots | Every `View` + Compose-semantics node + WebView DOM node, with full layout/style/reflected properties |
| **Semantic tree** | `SemanticNode` | `SemanticTree.build(from: snapshot)` | Only nodes carrying a targeting signal (label, id, interactive), flattened to a label/role/frame summary |

The semantic tree is **derived from** the view tree (a filtered, slimmed
projection), not captured independently — it is NOT the platform/uiautomator
accessibility tree. The view tree is the source of truth.

Because both trees come from **one** capture, they always describe the same
frame. `ui report` fetches the agent's `/report` bundle: the in-app agent
captures one `Snapshot`, derives `SemanticTree` and `CompactObservation` from
that exact frame, and returns all three together. A separate `/semantics` or
`/compact` round-trip could observe the UI mid-change and yield trees that
disagree, so those endpoints remain for direct protocol use rather than report
generation.

Command → tree mapping:

| Command | Tree it reads | Returns |
| --- | --- | --- |
| `ui report` | both (writes `snapshot.json` + `semantics.json`) | files |
| `ui tree` | **view tree** | indented `Node` hierarchy |
| `ui tree --semantics` | **semantic tree** | indented `SemanticNode` hierarchy |
| `ui compact` | view tree (filtered to interactive/labelled) | one line per item |
| `ui style` | view tree (every node with style or a declared gap) | geometry + style per node, each value in raw/dp/sp units and tagged with the channel it came through |
| **`ui node`** | **view tree** | a single `Node` — full view properties, not a semantic summary |
| `mutate` | view tree (resolves the concrete `View` to patch) | `MutationResult` |
| `act tap` (selector) | **semantic tree first, view tree fallback** | a resolved point |

So `ui node --test-id checkout.payButton` returns the **view-tree `Node`** that
carries that testId — the concrete `android.widget.Button` with its alpha,
elevation, background color, and app-attached metadata — *not* the trimmed
semantic node. If you want the semantic projection instead, read
`ui tree --semantics` or `semantics.json`.

The split, restated:

- `ui node` / `ui subtree` → **view tree** (`Node`)
- `ui tree --semantics` → **semantic tree** (`SemanticNode`)

Only the **action** path (`act tap`) is semantic-first; the **inspection**
path (`ui node`) is always the view tree. These are different concerns and
intentionally use different trees.

## Style evidence (`ui style`)

The question behind it is "does this screen match the design" — spacing between
elements, colours, font properties, and whether proportions hold across screen
sizes. Reticle answers **none** of those. It emits what only an in-process
observer can know and stops there.

Four channels reach style, they are not equally trustworthy, and the fifth row is
the one that makes the other four safe to believe:

```
  where the value came from                 tag                 typical properties
  ─────────────────────────                 ───                 ──────────────────
  a public field/getter on the           ─▶ [viewField]         textSize, textColor,
  view or its layer                                             padding, layer corners

  reflected out of a background          ─▶ [drawableReflect]   cornerRadius, borderWidth,
  Drawable — Android only, and can                              borderColor
  be stale on a themed/animated
  background: the weakest of the four

  Compose GetTextLayoutResult →          ─▶ [textLayout]        the whole text style of
  TextStyle (the action TalkBack                                one Compose Text
  invokes)

  WebView getComputedStyle               ─▶ [computedStyle]     domStyle*, verbatim and
                                                                never converted
  ───────────────────────────────────────────────────────────────────────────────────
  NOTHING can read it                    ─▶ styleGaps           ! backgroundColor
                                                                  unreadable: <reason>
```

Without the last row a missing key means either "the app set nothing" or "Reticle
cannot see it", and a consumer comparing against a design has no way to tell —
which is how an observer lies by omission. The four things `ui style` therefore
emits:

- **The values.** Padding rather than the gap between two frames, because a
  frame-to-frame measurement cannot say whether the space belongs to this view,
  its neighbour or their parent — which is exactly what a spacing spec states.
- **The units.** A raw length is meaningless without the screen it was measured
  on, and the raw unit is not the same on both platforms: the Android view tree
  measures in physical pixels, UIKit in points, which are already
  density-independent. `StyleUnits.lengthsAreDensityIndependent` is the one place
  that difference is decided; dividing an iOS point by `density` would scale it
  twice, and the shared fixture pins against exactly that. Text also renders in
  sp, which divides out `ScreenInfo.fontScale` as well and so separates "the app
  asked for the wrong size" from "the user enlarged text".
- **The provenance.** `Node.styleChannels` carries the channel above per property,
  and doubles as the allowlist of which `custom` keys count as style at all.
- **The gaps.** `Node.styleGaps` lists properties this node HAS and no channel can
  read, with a reason. Without it "the design says 600, the app has nothing" and
  "Reticle cannot see the weight" are the same observation. See
  [boundaries.md](boundaries.md) for the two that exist today.

What it deliberately does not do is compare. Deciding what the values ought to be
imports an external truth, a delta needs a tolerance, and "ignore the status bar"
is an exemption list — all three are the consumer's policy, which is why the
roadmap's `diff design` item was dropped rather than built. The projection is the
same shape for a design comparison, a cross-build check, or the same screen on two
devices, and Reticle does not need to know which.

`StyleObservation` in `reticle-core`, mirrored in `ReticleProtocol`, owns the
derivation AND its text rendering — both host renderers just call `render()`, so
the Kotlin helper and the Swift host cannot format one snapshot two ways. Pinned
for both by `reticle-protocol/fixtures/style-observation.cases.json`.

The DOM channel behaves deliberately differently from the native ones. Both bridges
(Android `WebViewBridge`, iOS the WKWebView twin) tag their 26 `domStyle*` keys
`computedStyle`, and the values pass through **verbatim** with their own suffixes —
a CSS `px` is neither a device pixel nor a UIKit point, and a page's zoom and
viewport scaling are not observable from in-process, so converting would be
arithmetic on an assumption. `StyleUnit.opaque` is what that looks like on the wire.
The other DOM-specific rule: `getComputedStyle` answers for every property whether
or not the page stated it, so a computed value equal to its CSS initial
(`auto`/`none`/`0px`/`static`) is dropped — the exact analogue of a null Android
background emitting no key. Measured on the sample fixture, that is the difference
between 26 lines per DOM node and 6.

One capture asymmetry is worth knowing. Compose semantics carries no style of its
own — it is an accessibility surface — so text style comes from the
`GetTextLayoutResult` action's `TextLayoutResult.layoutInput.style`, the same
public channel `ComposeTextRegions` already uses for link geometry. Values are
normalised to rendered pixels there, so `textSize` means one thing whether it came
from a `TextView` or a `Text`.

## Sub-node interaction regions (multi-region controls)

A single View can carry more than one tappable region — the classic case is an
agreement row: "I have read and agree to [Terms]", where the plain text
toggles a checkbox and the "Terms" segment opens a detail page. Both the view
tree and the semantic tree collapse this into **one node**, so neither can,
on its own, tell an agent where the two click targets are.

Reticle attacks this with `RegionProbe` (in `reticle-agent`), which runs three
discovery channels per View plus a fallback, all through documented runtime
APIs (validated by hand against a real app via Frida before being implemented
in-process). Results land on `Node.regions`, `Node.suspectedMultiRegion`, and
`Node.charGrid`.

| Channel | API | Reliability | Recovers |
| --- | --- | --- | --- |
| `span` | `Spanned.getSpans(ClickableSpan)` + `Layout` geometry | High | Char range + per-line pixel hit-rects + URL target |
| `a11yVirtual` | `View.getAccessibilityNodeProvider()` (ExploreByTouchHelper) | High | Virtual sub-node bounds + labels |
| `touchDelegate` | `View.getTouchDelegate()` → `getTouchDelegateInfo()` (API 29+) | High | Extended/forwarded hit-rect (unlabelled) |
| `textMarker` | in-text paired-bracket / markdown markers + `Layout` geometry | Medium | One region **per link** with its own rect, for self-drawn rows |
| `colorSpan` | `ForegroundColorSpan` ranges + `Layout` geometry | Medium | A re-colored run (the "highlight = link" pattern) with its rect + actual color |
| **fallback** | `Layout` → `CharGrid` + `suspectedMultiRegion` flag | Best-effort | Screen-X ↔ character mapping for substring targeting |

The honesty rule: if none of the standard channels resolve but the node still
looks multi-region (interactive TextView with a *structural* link marker — a
paired bracket or markdown link — but no spans and no child views), Reticle does
**not** invent regions. It sets `suspectedMultiRegion = true`, emits one
`textMarker` region per detected link (each with its own Layout-derived rect),
and attaches a `CharGrid` so an agent can also target an arbitrary substring by
coordinate — `CharGrid.approximate` is set true for bidirectional or unmeasured
text rather than silently returning a wrong rect. Detection is structural, not lexical: it
keys on the markup, never on natural-language keywords, so the probe stays
language- and domain-neutral (a general-purpose tool must not assume an app's
locale).

**An out-of-process window is invisible; lost focus is the evidence.** A permission
prompt, a biometric sheet or an autofill dialog is another process's window: it is in
no window of this app and no node of this tree, so a capture taken while one is up
looks entirely ordinary — every control still `tappable` — while input goes to the
prompt. Reticle cannot reach that window (in-process observation, by design), so it
reports the fact it CAN see: `screen.windowFocused` (Android `View.hasWindowFocus()`,
iOS `UIApplication.applicationState`), rendered by `ui compact` as
`window: UNFOCUSED …` ahead of the keyboard line, because in that state nothing in
the tree is actionable. It never claims what is on top.

The in-process **screenshot** is blind to that window too, which is why this flag
matters more than it first appears: measured with an iOS notification alert up, the
agent's screenshot showed only the app's own screen while a device-level
`simctl io screenshot` showed the alert plainly. An agent that falls back to "look at
the picture" is fooled exactly like the tree is.

**The screenshot's own blind spots are labelled, not left blank.** A picture is
believed more readily than a tree, so where it silently omits something the omission
must be stated. The two paths fail in exactly complementary ways, both measured with
`scenario.screenshotDegrade` on an emulator:

| what | in-process capture (`agent /screenshot`) | device capture (`adb exec-out screencap`) |
| --- | --- | --- |
| `SurfaceView` content | **missing** — its own surface is composited by SurfaceFlinger, so the Canvas walk leaves rgba `0,0,0,0` | present (magenta, `255,0,255`) |
| `FLAG_SECURE` window | present, unaffected | **blanked** — the whole frame is `0,0,0,255` |

So the node carries `custom["pixelStatus"] = "unavailable"` (compact:
`pixels:unavailable`) and the window carries `custom["screencapStatus"] = "blank"`
(compact: `screencap:blank`), and `reticle ui screenshot` prints a `degraded:` line
naming what the picture it just wrote is missing. iOS has the same shape for a
different reason: the keyboard's host window refuses to render into a borrowed
context (`drawHierarchy` returns false, and the capture skips it rather than let it
black out everything below), so that window is marked `pixels:unavailable` too —
measured, the agent's picture shows the app's plain background where
`simctl io screenshot` shows the keys.

**A blocked DOM read is reported, not implied.** `alert()`/`confirm()` block the
page's JS thread until the app dismisses them, so `evaluateJavascript` cannot call
back and the DOM read hits its 750ms budget. The bridge degrades to L0 (the web
view stays one opaque node) — but an absence is ambiguous, so the host node gets
`custom["domStatus"] = "unavailable"` and compact renders `dom:unavailable`. Same
marker for JS disabled or a read that outran its budget under animation load.

**Scroll capability is evidence, not a promise.** A recycling or lazy container
(`RecyclerView`, `LazyColumn`, `UIScrollView`/SwiftUI `List`) binds only its
visible window, so a far-down row has no node, no frame, and no selector at all —
absent, not off-screen. `Node.scroll` reports whether the container can still move
in each direction right now (Android `canScrollVertically/Horizontally`, limited
to `ViewGroup`s because an overflowing `TextView` also answers true; Compose's
semantics scroll-axis ranges, honouring `reverseScrolling`; iOS content offset vs
content size), and compact renders it as `scroll:up,down`. It deliberately does
NOT claim what would come into view — where a missing element lives is not
knowable from a snapshot. Selector-miss diagnostics on both hosts name the
scrollable containers so "not found" can be told apart from "not bound yet".

**Compose text is decomposed through the semantics surface, not `Layout`.** The
channels above read `Spanned` + `Layout`, neither of which exists in Compose, so a
`Text` with two `LinkAnnotation`s used to arrive as one node with no regions —
the same agreement row that decomposes fine as a `TextView`. `ComposeTextRegions`
closes that asymmetry with the surface Compose already exposes to accessibility:
`SemanticsProperties.Text` gives the `AnnotatedString` (its `getLinkAnnotations`
are the authored ranges) and the `SemanticsActions.GetTextLayoutResult` action —
what TalkBack invokes — returns a `TextLayoutResult`, i.e. the laid-out glyph
geometry that stands in for `Layout`. One `span` region per link with per-line
rects and the url/tag as target, plus a char grid for substring targeting. Purely
reflective, failing closed to zero regions, so the agent keeps no compile-time
Compose dependency.

**Virtual-node ids are the app's, not the framework's.** A provider hands out the
ids the app chose in `getVisibleVirtualViews` — dense 0-based indexes for one
control, stable domain ids (a seat number, a row id) for the next. Probing
`0 until childCount` therefore recovers nothing for half of real controls, which
is how this channel shipped for a while: it failed *closed*, so a self-drawn
control merely looked unaddressable. Resolution order is now the host node's
declared child ids → the androidx `ExploreByTouchHelper`'s own
`getVisibleVirtualViews` (app-side code, so the platform's non-SDK policy doesn't
apply to reaching it) → the dense probe. The iOS probe has the same shape of
trap and the same fix: a container may expose sub-elements through the
`accessibilityElements` array **or** through `accessibilityElementCount()` +
`accessibilityElement(at:)`, and both are read.

**A touch delegate's rect is public; its target is not.** The bounds used to come
from a `TouchDelegate.mBounds` reflection, which the platform blocks
(`api=max-target-o`) for anything targeting O or newer — the channel was dead on
every modern app, silently. It reads the public
`TouchDelegate.getTouchDelegateInfo()` (API 29+) instead, and reports nothing
below API 29 rather than guessing the view frame. The forwarded region carries no
label, because `getTargetForRegion` resolves its target only through an
accessibility connection that an in-process observer doesn't have; the rect is
honest geometry with an unknown target, addressable as
`act tap --region touchDelegate` (a `--region` needle also matches a region
source, not just a label).

**Wrap-boundary correctness.** `Layout.getPrimaryHorizontal(offset)` returns the
*next* line's left edge when `offset` sits exactly on a soft line break, which
would collapse a link ending at a wrap into a bogus full-width rect (a real
multi-link agreement row, wrapped across two lines, exposed this). `rectsForRange`
picks the end line from the last character actually in the range and uses
`getLineRight` when a segment reaches a line's visible end — verified on-device
that all three links of a wrapped three-link row resolve to distinct, correct
hit-rects.

### Text color as a link signal

The view tree always carries text color: every node exposes `custom.textColor`
(the base `currentTextColor`) and, for text nodes with a link tint,
`custom.linkTextColor` (`android:textColorLink` — the color clickable spans
render with). A region also carries its own `color` (`#AARRGGBB`) when its run
is colored differently from the base text, which is the single strongest
"this looks tappable" signal — clickable phrases are almost always tinted.

Three sources of a region's color, by recoverability:

- **`ForegroundColorSpan`** — color + exact char range live in the span;
  recovered precisely. Surfaced as a `colorSpan` region when the run is *not*
  already a real `ClickableSpan` (the common "color the phrase, hit-test it in
  one `OnClickListener`" pattern), or attached to a `span` region's `color`
  when it overlaps a clickable span. Verified on-device: a blue highlighted run
  with no ClickableSpan surfaced as `colorSpan color=#FF1A73E8` with a precise
  rect, and tapping it by its on-screen substring fired the row handler.
- **`linkTextColor`** — a real `ClickableSpan` with no explicit color renders in
  the View's `textColorLink`; that tint isn't in the span, so Reticle reads
  `getLinkTextColors()` and attaches it to the span region's `color`. Verified:
  the span case reported `color=#FF008577` (the theme link color).
- **Self-drawn `onDraw` color** — a control that paints colored text itself
  exposes no span and no API; this color is **not** recoverable. Reticle reports
  nothing rather than guessing, and the run stays targetable by substring via the
  char grid. Row in [boundaries.md](boundaries.md).

Caveat: color is a *heuristic* link signal, not proof — a non-tappable word can
be colored for emphasis. So `colorSpan` regions are candidates an agent weighs
(often alongside `suspectedMultiRegion` and the row's clickability), not
asserted links.

### Markerless multi-phrase text — precise to a phrase

Many agreement rows have NO bracket / markdown / span markup at all — a row like
"By signing in you accept the User Agreement and Privacy Policy" where only the
two policy phrases are tappable, with the phrase boundaries living solely in the
control's private `onTouchEvent`. Reticle cannot *discover* such phrases (nothing
structural marks them) **and** does not guess from wording — keying on
natural-language keywords would make the probe locale-specific, which a
general-purpose tool must avoid. So it emits **no** regions and does **not** set
`suspectedMultiRegion`; instead the `CharGrid` — emitted for *every* text node —
still lets an agent hit a phrase precisely by substring:

```bash
reticle act tap --package <pkg> --test-id agreement.plain --region "User Agreement"
reticle act tap --package <pkg> --test-id agreement.plain --region "Privacy Policy"
```

`SelectorResolver` finds the substring's character range in `CharGrid.text` and
maps it to a screen rect. Verified on-device: each policy phrase resolved to its
own coordinate and a non-link prefix to its own spot, each firing the correct
handler. The substring is matched verbatim against the on-screen text, in any
language.

### Font / size / spacing / line-height compatibility

The `CharGrid` is robust across fonts, text sizes, line spacing, and line
height **by construction**, because every coordinate is read from the laid-out
`android.text.Layout` rather than derived by Reticle:

- **Horizontal:** `CharLine.xOffsets` stores the real screen X at *every*
  character boundary, sourced per-offset from `Layout.getPrimaryHorizontal`.
  These are the exact glyph advances the framework computed, so proportional
  fonts, bold/italic, per-span size changes, letter-spacing, and mixed
  CJK/Latin/emoji runs are all handled — there is no equal-width interpolation
  (the previous implementation interpolated and would drift on mixed text).
- **Vertical:** `top`/`bottom` come from `Layout.getLineTop`/`getLineBottom`,
  which already fold in font ascent/descent, `lineSpacingExtra` (`+N`),
  `lineSpacingMultiplier` (`xN`), and per-line height — so taller lines, custom
  line height, and multi-size text yield correct line boxes.
- **Scroll/padding:** offsets add `getLocationOnScreen` + `totalPaddingLeft/Top`
  − `scrollX/scrollY`, so scrolled or padded text stays accurate.

Where it is only a best effort, the grid says so with
`CharGrid.approximate = true` rather than returning a confidently-wrong rect:
bidirectional text, and text not yet measured. Both are rows in
[boundaries.md](boundaries.md) — that file, not this one, is where the complete
list lives.

One shape worth knowing here because it is not a limit: a phrase spanning a soft
wrap yields one rect **per line** (`rangeRects` returns a list), and the CLI taps
the first, which is the correct on-screen start.

Targeting a region from the CLI:

```bash
reticle ui regions snapshot.json                       # list all multi-region nodes
reticle act tap --package <pkg> --test-id agreement.span     --region "《Terms》"
reticle act tap --package <pkg> --test-id agreement.markdown --region "《Privacy》"
```

The resolver tries a discovered region whose label matches the substring first
(real hit-rect), then the char grid (substring → character range → rect), and
**fails loudly if neither matches** rather than tapping the row's centre — which,
on an agreement row, is the checkbox rather than the link.

### What this does and doesn't solve

- **Standard controls (span / TouchDelegate / virtual a11y nodes):** fully and
  reliably decomposed — real hit-rects, verified on-device against both a
  `ClickableSpan` row and a self-drawn control.
- **Fully self-drawn controls (e.g. a `MarkdownCheckBox` that splits regions in
  a private `onTouchEvent` over plain-String text):** the region boundary lives
  only in app code and is recoverable by **no** static tree. Reticle flags it
  and hands over a char grid; the agent targets the substring by coordinate.
  This is the documented ceiling of node-based UI forensics: when a control
  draws itself and hit-tests privately, no static tree can recover the boundary.
  Its row in [boundaries.md](boundaries.md) is **Pure-Canvas controls with no
  accessibility surface**, which is the same mechanism at its extreme.

## Selector resolution order

This applies to the **action** path only (`act tap`, `act wait`'s success test,
and the resolve step shared by selector-driven commands). The rule is "use the
semantic tree first for movement and input; fall back to view frames only when no
semantic match exists":

0. Explicit `--point x,y` — the escape hatch for when resolution cannot work, so
   nothing overrides it, not even a `--region` needle passed alongside
1. `--region "substr"` within the selected node: a discovered region whose label
   contains the needle (case-insensitively), then a region named by its `source`
   (`--region touchDelegate`), then the char grid (substring matched **verbatim**)
   — the multi-region case above
2. Semantic tree by `testId` → `resourceId` → `cssSelector` → `ref` → `label`
3. View-tree frame by the **same** precedence, for a node the semantic projection
   dropped

Every first-match lookup walks the tree in **document order** (DFS from the root,
then any orphan ref in sorted order), so an app that repeats a `testId` resolves
to the same node on both platforms and across runs.

A `--region` that matches nothing is an **error**, never a fall-through to the
whole node: on an agreement row the node's centre toggles the checkbox instead of
opening the terms, so a silent downgrade there is a successful-looking tap on the
wrong target. A `--label` matching two visible nodes in different subtrees is an
error for the same reason; nested duplicates (a row repeating its child's text)
resolve to the innermost.

Note this is the *opposite default* from inspection: actions prefer the
semantic tree (it's the honest input surface, and the only one Compose
exposes), while `ui node` always returns the richer view-tree node.

**Two implementations, one table, both in the protocol module.** Android resolves
in `SelectorResolver` (Kotlin, `reticle-core`) and iOS in `SelectorResolution`
(Swift, `ReticleProtocol`), because the two hosts are different programs. Both are
pinned by `reticle-protocol/fixtures/selector-resolution.cases.json`, which is the
authority for every rule above — the file exists because the two had silently
drifted on all of them.

The Kotlin half used to live in the helper, i.e. a layer above the module the
fixture describes, and that asymmetry cost more than tidiness: a rule pinned by a
shared fixture had no obvious home, so the next one could as easily land in the
host as beside its twin. Its refusals moved with it — `AmbiguousLabelException` and
`RegionMissException` are `reticle-core` types now rather than `CliError`
subclasses, which costs nothing (the helper's RPC layer reports any throwable by
message) and keeps a refusal travelling with the rule that raises it. They stay two
types because a poll loop must tell them apart: an ambiguity makes an answer
`unknowable`, while a phrase not yet on screen is an honest negative a `wait`
should keep waiting on.

## Module layout

Which box in the [first diagram](#the-shape-of-the-system) each module is:

| Module | Kind | Contents |
| --- | --- | --- |
| `reticle-core` | Pure JVM | Snapshot / semantic / region models + wire protocol + the text projections (`Render`, `StyleObservation.render`) — one implementation of `reticle-protocol` |
| `reticle-swift` (`ReticleProtocol`) | SwiftPM library | The Swift implementation of `reticle-protocol`: Codable models, omit-defaults JSON, `SemanticTree`/`CompactObservation` derivations, `PortMap`, and `Render` — the twin of `dev.reticle.core.Render`, so the tree/compact/semantics/regions text is formatted from the protocol module on both platforms rather than once per host. Depended on by both the iOS agent and the Swift host so neither re-ports the protocol. |
| `reticle-agent/android` (`:reticle-agent:android`) | Android AAR | In-process server, capture, Compose bridge, region detection, mutation, screenshot, auto-start |
| `reticle-agent/ios` (`ReticleKit` + `ReticleInjection` + `ReticleInjectionBootstrap`) | SwiftPM package | In-process iOS agent: loopback server, UIKit capture, accessibility-derived SwiftUI (`axElement`) bridge, allowlist mutation, in-process screenshot, `Reticle` facade, and DYLD-constructor / linked auto-start. Emits `platform="ios"` protocol JSON. Invisible to Gradle. |
| `reticle-helper` | Android host layer (Kotlin) | adb wrapper, runtime client, input backend, JDWP injector, selector *diagnostics* (resolution itself is `reticle-core`, beside its Swift twin). Ships as the no-JDK native `reticle-helper`; its only entry points are `helper` (the RPC server the Swift host drives), `version`, `help`. |
| `reticle-host` | Swift host CLI + daemon | The user-facing `reticle` (macOS arm64). Selects a platform via `--target` (default `android`) behind the typed `HostBackend` interface (one method per capability, typed requests/results): Android device commands go through `AndroidBackend`, the single place the helper's JSONL method names and parameter keys are spelled; **iOS is handled natively in-host** (`IosHelperClient` — `simctl`/`devicectl` + direct loopback HTTP + private CoreSimulator HID), no helper. Also owns `reticle serve`, session events, panel, proxy/MITM, and mock state. Internally four SwiftPM library targets stacked bottom-up — `ReticleHostShared` (dependency-free `JSONValue` / event models / `HelperError` / the `HelperCalling` call surface / the version constant), `ReticleNetworkLane` (the capture proxy + MITM + mock engine, behind the `NetworkEventSink` interface), `ReticleHostIos` (the iOS platform backend: `simctl`/`devicectl`, loopback HTTP, the wait/scroll-to/verify loops, CoreSimulator HID — depending on nothing above it, so the daemon cannot reach into platform code and the backend cannot reach up into the CLI), and `ReticleHostCore` (daemon, CLI, panel, Android helper clients, grouped as `Daemon/` `CLI/` `Android/`) — plus the `ReticleHost` executable. `ReticleHostCore` `@_exported`s the lower three, so the split is an internal boundary, not an API change. |
| `sample-app` | Android app | Demo linking the Android agent, proving the round trip |
| `sample-app-ios` | iOS app | Demo with a `linked` target (links `ReticleKit`) and a `noagent` target (injection test), proving the iOS round trip |

(`reticle-agent/` is a grouping directory — no build script of its own; the
`ios/` agent is a sibling of `android/`, built by SwiftPM (`harmony/` by hvigor
when it lands) and invisible to Gradle.)

## What stays on disk vs. what goes to the agent

Full snapshots are written to disk (`ui report` → `snapshot.json`), and agents
are handed the **compact observation** by default (`ui compact`), then query
specific refs/nodes on demand (`ui node`). `reticle serve` persists daemon
events, body artifacts, mock config, and action traces under the session
directory. This keeps token cost low while preserving full fidelity for when
it's needed.

Action traces follow the same split, and it took two changes to actually hold.
The manifest's diff is the compact layer, but it cited bare refs — so reading it
meant loading the 100KB+ snapshot next to it, and the split silently collapsed.
Each change now carries the changed node's identity (once per ref), which is
what makes the compact layer answerable on its own. And because the diff is
capped, **rank decides what survives**: by field (appearance and text before the
geometry tail), then by how addressable the node is. Ordering by ref instead —
which is what it did — let a scrolling list's frame churn evict the one node that
appeared, i.e. the cap silently chose the least useful hundred.

`reticle trace log` is the run-level analogue of `ui compact`: a few lines per
action instead of a directory per action. Every loss is stated (`…N more` for
the digest, `truncated` in the manifest for the capture), so a short read is
never mistaken for a quiet screen. Recording is on by default and lands in an
auto session when no daemon owns one; pruning is gated on a marker file Reticle
writes, never on the directory's name, so it can only ever delete its own.
Both diff ports are pinned by `reticle-protocol/fixtures/action-trace-diff.cases.json`.

## Honest boundaries: what Reticle cannot reach

Collected in **[boundaries.md](boundaries.md)** — the marker vocabulary
(`window: UNFOCUSED`, `dom:unavailable`, `dom:unsupported-kernel`,
`pixels:unavailable`, `screencap:blank`, `scroll:up,down`,
`! <property> unreadable`, `act wait` → `UNKNOWABLE`), the boundary table with
what each one emits instead and what pins it, and how `act wait` consumes that
table.

That file is the **complete** list, and this one deliberately keeps none of its
own: where a section above hits a limit it states the mechanism and links the row,
rather than half-repeating the table. A limit discovered and written down only
here would make `boundaries.md` read as complete while being wrong — which is the
reason the two documents were split.

The rule, restated here because everything above depends on it: **an unreachable
thing must produce evidence naming itself, never silence.** A boundary earns a row
only when the mechanism is understood, and "not exercised" is written down where it
is rather than implied by a missing test.
