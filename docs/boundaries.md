# Honest boundaries

What Reticle cannot reach, and what it says instead.

An in-process observer has real limits, and the danger is never the limit itself —
it is a limit that looks like an ordinary, empty-ish observation. This file is the
single place they are collected, so an agent stops guessing and a contributor stops
re-investigating. **The rule for all of them: an unreachable thing must produce
evidence naming itself, never silence.**

Platform mechanism detail lives one level down: [ios.md](ios.md) explains *why*
each iOS-specific row is unreachable (real-device input, DYLD injection, SwiftUI
accessibility, the HID surface) including the routes that were tried and rejected.
This file is the index of facts; that one is the evidence behind them.

It lives apart from [architecture.md](architecture.md) because the two answer
different questions. That document explains how Reticle works and is read once;
this one is a reference table, consulted per case — and it is the file a new
boundary must be added to (see AGENTS.md). Splitting them also keeps the
architecture doc from being three documents in one: a design explanation, a
tutorial, and an errata list.

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
| `! <property> unreadable: <reason>` | Rendered by `ui style` from `Node.styleGaps`: this node HAS that style property and no channel can read it. The property-granular form of this whole table — an absent key would read as "the app sets no corner radius" |
| `act wait` → `UNKNOWABLE` + `reasons:` | A wait's predicate did not hold **and** one of the markers above made the answer unobservable. Distinct from `ABSENT`, which is an honest negative |

## The boundaries themselves

| Boundary | Why it is unreachable | What Reticle emits instead | Pinned by |
| --- | --- | --- | --- |
| **Closed shadow roots** | `{mode:'closed'}` gives the page itself no `shadowRoot` handle, so the traversal script has nothing to walk. Open roots ARE pierced | The host element is still captured as a normal DOM node (measured: `#closed-shadow-host` at its real rect); only its innards are absent. Target the host, or ask the app to open the root | `complex` web fixture — both twins on one screen, the absence asserted |
| **Cross-origin iframes** | `contentDocument` access throws by browser policy; nothing in the app can override it. Same-origin frames are pierced, with the page offset accumulated | The frame element stays a normal node with its rect; no children | Same-origin case is pinned; the cross-origin case is **not exercised** (needs a second origin, and both suites run offline) |
| **Third-party WebView kernels (X5/TBS, UC)** | `WebViewBridge` is typed on `android.webkit.WebView`. A reflective adapter was rejected: unverifiable without a real kernel sample | `dom:unsupported-kernel` + `custom.domKernel` naming the class, and a `--css` miss that explains the wall | `scenario.foreignKernel` (stand-in beside a real WebView) |
| **Bitmap-baked text** | Text drawn into an image has no text node anywhere. OCR is out of scope — it would be a guess wearing an observation's clothes | The image node with its frame and `domImage*`/resource metadata. A **Lottie** is the exception, not the rule: its text layers are recovered from the parsed composition | `scenario.lottieOnlyDialog` (recovery); no OCR path exists by design |
| **Compose `background` / `clip` / `border`** | These are draw modifiers: draw operations with no semantics projection and no public runtime handle. Reflecting the modifier chain off `LayoutNode` was rejected — its shape is not API and differs between Compose releases, so the value could not be verified against a public contract. TEXT style is the exception and is fully recovered: `GetTextLayoutResult` hands back the `TextStyle` the text was laid out with (size, weight, family, colour, line height, letter spacing, alignment) | `styleGaps` on every `composeSemantics` node names `backgroundColor` and `cornerRadius` with `compose-draw-modifier`, so `ui style` prints `! backgroundColor unreadable: …` rather than omitting the key. The node's rect is still exact, so the pixel channel can answer the colour question | `style-observation.cases.json` (the gap renders); `scenario.compose` (text style over the live channel) |
| **A character grid over bidirectional text, or over text not yet measured** | `Layout.getPrimaryHorizontal` stays per-offset correct under BiDi, but one *logical* substring can map to a **non-contiguous visual span**, so a per-line rect may over- or under-cover it. And before the first measure pass `getLayout()` is null, so there are no line boxes to read at all | `CharGrid.approximate = true` rather than a confidently-wrong rect — the flag is the whole point, since the grid still resolves and a caller must know the rect is a best effort. Everything else about the grid is exact by construction: every coordinate comes from the laid-out `Layout`, never from Reticle's own arithmetic, so proportional fonts, per-span sizes, letter spacing, line-spacing multipliers and mixed CJK/Latin/emoji are all already folded in | `CharGridTest`; the LTR path is exercised throughout `scenario.agreements` — **the BiDi case is not exercised** (no RTL fixture in the repo) |
| **The colour of a run a control paints in its own `onDraw`** | A `ForegroundColorSpan` carries colour + char range, and a `ClickableSpan` without one renders in the View's `textColorLink` (readable via `getLinkTextColors()`) — but a control that paints coloured text itself exposes neither a span nor an API for it. Nothing to read | No `color` on the region at all rather than a guess. The run stays targetable by substring through the char grid, so the colour being unknown does not cost reachability. Note that colour is only ever a *heuristic* link signal here — a non-tappable word can be tinted for emphasis — so `colorSpan` is a candidate an agent weighs, never an asserted link | `scenario.agreements` (both recoverable sources measured on-device: `colorSpan color=#FF1A73E8`, span `color=#FF008577`) |
| **An Android `Typeface`'s family name** | `Typeface` exposes weight and slant and nothing else — there is no getter for the family, so the one text property a design always states by name is unreadable on the View channel. Not a platform boundary: Compose text carries `fontFamily` through `TextStyle`, and the DOM carries it through computed CSS | `styleGaps["fontFamily"] = "android-typeface-exposes-no-family"` on every `TextView` node | `snapshot.golden.json` (the gap is on the wire) |
| **Pure-Canvas controls with no accessibility surface** | A canvas is one View; sub-controls exist only in the app's own hit-testing | Whatever channel the app DOES expose: virtual a11y nodes, a touch delegate, link/color runs, or the char grid. With none of them, only the canvas rect and coordinates | `scenario.canvasControl` (both id conventions + a touch delegate) |
| **Out-of-process system UI** — permission prompts, biometric sheets, share sheets, Custom Tabs / `SFSafariViewController`, the IME | Another process's window: in no window of this app, in no node of this tree, and invisible to the in-process screenshot too | `screen.windowFocused` → `window: UNFOCUSED` (a fact about THIS app, never a claim about what is on top); for the IME, `screen.keyboard` + `occluded-by:keyboard` + `act hide-keyboard` | `scenario.permission` (both platforms, loss AND clearing); login keyboard trap |
| **Screenshot blind spots** | A `SurfaceView`'s surface is composited by SurfaceFlinger (absent in-process); `FLAG_SECURE` blanks the device-level capture; an iOS keyboard host window refuses to render into a borrowed context | `pixels:unavailable` / `screencap:blank` + a `degraded:` line on the picture naming what is missing and which path would show it | `scenario.screenshotDegrade` (labels and pixels both asserted) |
| **DRM / protected video** | Same mechanism as a `SurfaceView`, plus a protected surface the system will not let anyone read | The `pixels:unavailable` treatment above; the player's controls are ordinary views and stay targetable | **Not exercised** — no DRM sample in the repo. Listed because the mechanism is the one already measured |
| **Non-debuggable release builds without the AAR** | JDWP attach requires a debuggable app; Frida/root are out of scope by design | `app inject` fails loudly with the reason rather than half-attaching | `noagent` flavor covers the debuggable-inject path |
| **Real-device iOS input** | The simulator HID surface has no device equivalent reachable from the host | `act activate` (in-process, the device analogue of a tap) works; coordinate taps are refused with that guidance | `scripts/e2e-ios-device.sh` |
| **Flows dropped by a full capture backlog** | Artifact writes are slower than a traffic burst. The lane drains Loom's stream instantly onto a worker so the engine is never back-pressured, but the worker's own backlog is bounded (4096) and a long enough burst overflows it | `network.advisory` on both edges: `capture-backlog-overflow` when recording starts falling behind, `capture-backlog-recovered` with the episode's loss count once it catches up. Two edges, not one event per drop, so a storm isn't its own flood | `LoomCaptureLaneTests` (overflow announced once, recovery carries the count) |
| **Loom's own stream buffer dropping** | `AsyncStream` with `.bufferingOldest(512)` drops without any signal a subscriber can observe. Draining instantly makes this very unlikely, but "unlikely" is not "detectable" | **Nothing — this one is genuinely silent**, and it is listed here rather than implied by its absence. Closing it needs a dropped-flow counter on Loom's side; the Reticle-side backlog advisory above covers only losses Reticle itself caused | **Not exercised** — unobservable from this side by construction |
| **Flows aged out of the replay buffer** | `replay` re-sends from Loom's bounded in-memory ring (2000), which Reticle deliberately does not persist — `events.jsonl` is the evidence, the ring is only what can still be *acted on*. An older exchange is fully evidenced and no longer replayable | `GET /sessions/current/flows` stamps every result `replayableOnly: true`, so an empty list reads as "nothing replayable matches" rather than "this never happened"; `replay` on an aged-out id fails naming the reason. Without a capture proxy the endpoint 404s instead of returning an empty list | `FlowQueryRouteTests` (scope declared, 404 without a lane); `scripts/e2e-proxy.sh` (found by predicate against a live ring) |
| **WebSocket frames past the capture cap** | Reticle stops at 1000 frames per socket (an event per frame would let one chatty socket bury the session); Loom stops at 10k frames / 5 MB, which can bite first on a few large ones. The socket stays open and keeps talking either way | One `network.websocket` event with `capReached: true`, `framesRecorded`, and `framesNotRecorded` — emitted the moment the cap is reached, not at close, since the close may never come. Without it the ensuing silence would read as a quiet socket | `LoomCaptureLaneTests` (both caps, announced exactly once); `scripts/e2e-proxy.sh` (real socket, frames in order both directions) |
| **Bodies past the capture cap** | Two caps sit in the chain — Loom's, while it relays every byte to the peer, then `NetworkBodyStore`'s. Past either, the recorded body is a prefix of what actually flowed; the bytes were never kept, so no offset can page into them | The artifact plus true wire size: `requestBodyBytes`/`responseBodyBytes` + `…BodyTruncated` on a capture event, and `bodyComparisonPartial` on a replay diff — under which a prefix match is never reported as `isIdentical` | `NetworkReplayDiffTests` (partial comparison refuses the identical verdict; differing wire sizes still assert a change) |
| **Whether a field a `type` targeted was secure** | Nothing in the capture layer marks a field as a password: not the view tree, not the accessibility surface, not the DOM bridge. There is no flag to read, so there is no rule Reticle could apply | An action trace records `params.text` **verbatim** — the alternative, guessing at which fields deserve redaction, would be worse than a stated one. What this costs is stated rather than hidden: recording is on by default (see below), so a typed password lands in `~/.reticle/sessions/<session>/traces/*/trace.json` in the clear, on the developer's own machine. `RETICLE_NO_AUTO_TRACE=1` turns recording off; a snapshot never contains a secure field's contents, so this is the one artifact that can hold more than the rest | `TraceDigestTests.recordsWhatWasTyped`; `ActionTraceParams.RECORDED` is the allow-list |
| **Changes past the diff cap** | An action trace diffs two whole snapshots, and a screen transition legitimately produces hundreds of changes. Keeping all of them would make the manifest as expensive to read as the snapshots it summarises | The cap spends its budget by rank — appearance and text before geometry, addressable nodes before anonymous scaffolding — and then says what it shed: `truncated` carries the total, the kept count, and a per-field breakdown of the remainder. Both snapshots are still on disk, so nothing is lost, only summarised | `action-trace-diff.cases.json` (ranking and the truncation marker, pinned in both languages) |

## How a wait consumes this table

`act wait` is the one command whose whole answer is shaped by the markers above, so
it is worth stating the mapping once. Its outcome is three-state:

- `resolved` — the predicate held. Occlusion, invisibility and lost focus become
  **caveats** here, never a downgrade: the success test is resolution through the
  act's own path, so a `resolved` wait guarantees the next `act` resolves the same
  way, whether or not a human could see the thing.
- `absent` — the predicate did not hold and **no** marker above applied. An honest
  negative a caller may act on.
- `unknowable` — the predicate did not hold and a marker did apply (lost focus, an
  unreadable DOM, an unsupported kernel, travel left in the **topmost** window's
  scroller, a screen that never settled, or a `--label` the resolver refused to
  disambiguate). Not a negative.

The scroll case is scoped to the topmost window on purpose: a background window's
scroller can never bring the target into view, and citing it was measured both
making `absent` nearly unreachable and producing misleading advice
(`scroll-to --css …` for a DOM element behind a blocking JS modal). `WaitVerdict`
in `reticle-core`, mirrored in `ReticleProtocol`, owns this mapping for both
platforms and is pinned by
`reticle-protocol/fixtures/wait-classification.cases.json`.

Two rules keep this list honest. A boundary earns a row only when the mechanism is
understood — "not exercised" is written down where it is, rather than implied by a
missing test. And nothing here is worked around by inference: no OCR, no
guess-from-screenshot targeting, no reflective bridge that cannot be verified. The
agent is told what is unknown; it decides what to do about it.
