# Reticle Architecture

Reticle inspects the app that is actually running and drives real input. It
rests on three mechanisms: getting observation code into the target process,
talking to it over a loopback channel, and synthesizing real input from the
host. This document describes each, then the UI-tree model, selectors, and the
multi-region detection that targets a specific phrase inside a single View.

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
events. HTTPS traffic is visible as CONNECT tunnels unless `--proxy-mitm` and
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
through. Rules can optionally narrow by host wildcard and query key/value
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

## The embedded-Web boundary: WebView DOM

An `android.webkit.WebView` remains a real View node, but Reticle now also reads
its visible DOM through a default-on, read-only bridge when JavaScript is enabled.
`WebViewBridge` runs a traversal script with `evaluateJavascript`, folds DOM
rectangles into screen coordinates, and appends each element as a `NodeKind.domNode`
child under the WebView. The script does not mutate page state.

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
coordinate — `CharGrid.approximate` is set true for BiDi/wrapped text rather
than silently returning a wrong rect. Detection is structural, not lexical: it
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
  exposes no span and no API; this color is **not** recoverable. Honest limit:
  Reticle reports nothing rather than guessing, and the run is still targetable
  by substring via the char grid.

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

Honest limits, all flagged via `CharGrid.approximate = true` rather than
returning a confidently-wrong rect:

- **BiDi / RTL lines:** `getPrimaryHorizontal` is still per-offset correct, but a
  single logical substring can map to a *non-contiguous* visual span, so a
  per-line rect may over- or under-cover; the grid is marked approximate.
- **`getLayout() == null`** (text not yet measured): grid has no lines and is
  marked approximate.
- A phrase spanning a soft wrap yields one rect per line (`rangeRects` returns a
  list); the CLI taps the first rect, which is the correct on-screen start.

Targeting a region from the CLI:

```bash
reticle ui regions snapshot.json                       # list all multi-region nodes
reticle act tap --package <pkg> --test-id agreement.span     --region "《Terms》"
reticle act tap --package <pkg> --test-id agreement.markdown --region "《Privacy》"
```

`SelectorResolver` tries a discovered region whose label matches the substring
first (real hit-rect), then the char grid (substring → character range → rect).

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

## Selector resolution order

This applies to the **action** path only (`act tap`, and the resolve step
shared by selector-driven commands). The rule is "use the semantic tree
first for movement and input; fall back to view frames only when no
semantic match exists" — see `SelectorResolver`:

0. `--region "substr"` within the selected node (discovered region rect, then
   char-grid substring) — the multi-region case above
1. Explicit `--point x,y`
2. Semantic tree by `testId` → `resourceId` → `ref`
3. View-tree frame by `testId` → `resourceId` → `ref`

Note this is the *opposite default* from inspection: actions prefer the
semantic tree (it's the honest input surface, and the only one Compose
exposes), while `ui node` always returns the richer view-tree node.

## Module layout

| Module | Kind | Contents |
| --- | --- | --- |
| `reticle-core` | Pure JVM | Snapshot / semantic / region models + wire protocol (one implementation of `reticle-protocol`) |
| `reticle-swift` (`ReticleProtocol`) | SwiftPM library | The Swift implementation of `reticle-protocol`: Codable models, omit-defaults JSON, `SemanticTree`/`CompactObservation` derivations, `PortMap`, and the host-side tree/compact/node renderers. Depended on by both the iOS agent and the Swift host so neither re-ports the protocol. |
| `reticle-agent/android` (`:reticle-agent:android`) | Android AAR | In-process server, capture, Compose bridge, region detection, mutation, screenshot, auto-start |
| `reticle-agent/ios` (`ReticleKit` + `ReticleInjection` + `ReticleInjectionBootstrap`) | SwiftPM package | In-process iOS agent: loopback server, UIKit capture, accessibility-derived SwiftUI (`axElement`) bridge, allowlist mutation, in-process screenshot, `Reticle` facade, and DYLD-constructor / linked auto-start. Emits `platform="ios"` protocol JSON. Invisible to Gradle. |
| `reticle-helper` | Android host layer (Kotlin) | adb wrapper, runtime client, input backend, JDWP injector, selector resolver. Ships as the no-JDK native `reticle-helper`; its only entry points are `helper` (the RPC server the Swift host drives), `version`, `help`. |
| `reticle-host` | Swift host CLI + daemon | The user-facing `reticle` (macOS arm64). Selects a platform via `--target` (default `android`): Android device commands are RPC calls to the native Kotlin helper; **iOS is handled natively in-host** (`IosHelperClient` — `simctl`/`devicectl` + direct loopback HTTP + private CoreSimulator HID), no helper. Also owns `reticle serve`, session events, panel, proxy/MITM, and mock state. Internally three SwiftPM library targets stacked bottom-up — `ReticleHostShared` (dependency-free `JSONValue` / event models / `HelperError`), `ReticleNetworkLane` (the capture proxy + MITM + mock engine, behind the `NetworkEventSink` interface), and `ReticleHostCore` (daemon, CLI, panel, per-platform host code) — plus the `ReticleHost` executable. `ReticleHostCore` `@_exported`s the lower two, so the split is an internal boundary, not an API change. |
| `sample-app` | Android app | Demo linking the Android agent, proving the round trip |
| `sample-app-ios` | iOS app | Demo with a `linked` target (links `ReticleKit`) and a `noagent` target (injection test), proving the iOS round trip |

(`reticle-agent/` is a grouping directory — no build script of its own; the
`ios/` agent is a sibling of `android/`, built by SwiftPM (`harmony/` by hvigor
when it lands) and invisible to Gradle.)

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

## What stays on disk vs. what goes to the agent

Full snapshots are written to disk (`ui report` → `snapshot.json`), and agents
are handed the **compact observation** by default (`ui compact`), then query
specific refs/nodes on demand (`ui node`). `reticle serve` persists daemon
events, body artifacts, mock config, and action traces under the session
directory. This keeps token cost low while preserving full fidelity for when
it's needed.

## Honest boundaries: what Reticle cannot reach, and what it says instead

An in-process observer has real limits, and the danger is never the limit itself —
it is a limit that looks like an ordinary, empty-ish observation. This section is
the single place they are collected, so an agent stops guessing and a contributor
stops re-investigating. **The rule for all of them: an unreachable thing must
produce evidence naming itself, never silence.**

The vocabulary that carries these facts, all rendered by `ui compact`:

| Marker | Means |
| --- | --- |
| `window: UNFOCUSED …` | Another process's window holds input focus; nothing in this tree is tappable right now |
| `keyboard: visible […]` + `occluded-by:keyboard` | The IME covers these items (it is never a node) |
| `occluded-by:<ref>` | An in-app window above this one covers its tap point |
| `dom:unavailable` | This web view's DOM could not be read *at capture time* (blocked JS thread, JS off, budget) — retry may help |
| `dom:unsupported-kernel` | A third-party WebView kernel: there is no DOM bridge for it at all — retry never helps |
| `pixels:unavailable` | This node's pixels are missing from the **in-process** screenshot |
| `screencap:blank` | This window blanks a **device-level** screenshot (`FLAG_SECURE`) |
| `scroll:up,down` | The container has travel left, so an absent row may simply be unbound |

### The boundaries themselves

| Boundary | Why it is unreachable | What Reticle emits instead | Pinned by |
| --- | --- | --- | --- |
| **Closed shadow roots** | `{mode:'closed'}` gives the page itself no `shadowRoot` handle, so the traversal script has nothing to walk. Open roots ARE pierced | The host element is still captured as a normal DOM node (measured: `#closed-shadow-host` at its real rect); only its innards are absent. Target the host, or ask the app to open the root | `complex` web fixture — both twins on one screen, the absence asserted |
| **Cross-origin iframes** | `contentDocument` access throws by browser policy; nothing in the app can override it. Same-origin frames are pierced, with the page offset accumulated | The frame element stays a normal node with its rect; no children | Same-origin case is pinned; the cross-origin case is **not exercised** (needs a second origin, and both suites run offline) |
| **Third-party WebView kernels (X5/TBS, UC)** | `WebViewBridge` is typed on `android.webkit.WebView`. A reflective adapter was rejected: unverifiable without a real kernel sample | `dom:unsupported-kernel` + `custom.domKernel` naming the class, and a `--css` miss that explains the wall | `scenario.foreignKernel` (stand-in beside a real WebView) |
| **Bitmap-baked text** | Text drawn into an image has no text node anywhere. OCR is out of scope — it would be a guess wearing an observation's clothes | The image node with its frame and `domImage*`/resource metadata. A **Lottie** is the exception, not the rule: its text layers are recovered from the parsed composition | `scenario.lottieOnlyDialog` (recovery); no OCR path exists by design |
| **Pure-Canvas controls with no accessibility surface** | A canvas is one View; sub-controls exist only in the app's own hit-testing | Whatever channel the app DOES expose: virtual a11y nodes, a touch delegate, link/color runs, or the char grid. With none of them, only the canvas rect and coordinates | `scenario.canvasControl` (both id conventions + a touch delegate) |
| **Out-of-process system UI** — permission prompts, biometric sheets, share sheets, Custom Tabs / `SFSafariViewController`, the IME | Another process's window: in no window of this app, in no node of this tree, and invisible to the in-process screenshot too | `screen.windowFocused` → `window: UNFOCUSED` (a fact about THIS app, never a claim about what is on top); for the IME, `screen.keyboard` + `occluded-by:keyboard` + `act hide-keyboard` | `scenario.permission` (both platforms, loss AND clearing); login keyboard trap |
| **Screenshot blind spots** | A `SurfaceView`'s surface is composited by SurfaceFlinger (absent in-process); `FLAG_SECURE` blanks the device-level capture; an iOS keyboard host window refuses to render into a borrowed context | `pixels:unavailable` / `screencap:blank` + a `degraded:` line on the picture naming what is missing and which path would show it | `scenario.screenshotDegrade` (labels and pixels both asserted) |
| **DRM / protected video** | Same mechanism as a `SurfaceView`, plus a protected surface the system will not let anyone read | The `pixels:unavailable` treatment above; the player's controls are ordinary views and stay targetable | **Not exercised** — no DRM sample in the repo. Listed because the mechanism is the one already measured |
| **Non-debuggable release builds without the AAR** | JDWP attach requires a debuggable app; Frida/root are out of scope by design | `app inject` fails loudly with the reason rather than half-attaching | `noagent` flavor covers the debuggable-inject path |
| **Real-device iOS input** | The simulator HID surface has no device equivalent reachable from the host | `act activate` (in-process, the device analogue of a tap) works; coordinate taps are refused with that guidance | `scripts/e2e-ios-device.sh` |

Two rules keep this list honest. A boundary earns a row only when the mechanism is
understood — "not exercised" is written down where it is, rather than implied by a
missing test. And nothing here is worked around by inference: no OCR, no
guess-from-screenshot targeting, no reflective bridge that cannot be verified. The
agent is told what is unknown; it decides what to do about it.
