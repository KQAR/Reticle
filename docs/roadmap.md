# Reticle Roadmap

**English** | [简体中文](roadmap.zh-CN.md)

Four docs, four jobs. `README.md` is how to use Reticle; `docs/architecture.md`
is how it works today; `docs/boundaries.md` is the **Honest boundaries** table, the
canonical list of what is structurally unreachable; **this file is where it is
going**: what
is left, in priority order, and which decisions are already settled so they are not
re-litigated.

Status: 2026-08-01, tracking 0.13.0. The capture/drive/evidence backbone is complete
and cross-platform; the **boundary-case sweep** (fifteen points) closed on
2026-07-25. What remains is listed under [What's left](#whats-left) — no section of
this document is a to-do list except that one.

---

## The goal, and the one scope decision

The end goal is **post-development E2E verification**: an agent drives a finished
feature on a real device and checks each step.

**Reticle provides evidence, not verdicts.** The product verbs are *observe / drive
/ capture*, never *assert*. It emits state, trees, network events, screenshots and
action traces; the agent (or a human, or a test framework) decides whether a step
passed. Consequence, binding on every item below: no `assert`/`expect` primitive
ever enters the protocol or the CLI. What gets optimized instead is evidence
quality — structured, diffable, comparable.

The defining line: **no root, no repackage, no byte-code hooking.** And three
ceilings that are structural rather than Android-specific, so no platform will
"fix" them:

- object inspection is class-metadata reflection + the reachable graph, never heap
  enumeration (for a real heap: `am dumpheap`, offline);
- network capture is host-side MITM, never passive interception of in-process
  traffic, and pinning is reported rather than bypassed;
- injection reaches **debuggable** apps (JDWP) or apps that link the agent —
  arbitrary release builds are Frida/root territory, which this project does not
  enter.

One more constraint binds every future item, because it is the difference between a
verification tool and a plausible one: **deterministic selectors stay the backbone.**
No natural-language target, no guess-from-a-screenshot mechanism is promoted to the
primary targeting path. `ui outline --live` + `@N` aliases are the acceptable
convenience layer; exploration is a coverage aid, never the verification path.

The cross-platform asset is therefore **the protocol**, not shared source: an agent
on any platform interoperates by speaking the same loopback contract, in whatever
language fits.

---

## Where things stand

| Area | State |
| --- | --- |
| **Observe** (Android) | View tree + Compose semantics + WebView DOM in one flat `ref → Node` map; semantic tree and compact observation derived in-process; regions/char grid for multi-target controls |
| **Observe** (iOS) | UIKit tree + SwiftUI `axElement` bridge (including links inside one `Text`) + `WKWebView` DOM; same protocol JSON |
| **Drive** | `tap` / `swipe` / `drag` / `scroll-to` / `type` / `hide-keyboard` / `activate`, selector-first with `--region`, `--label`, `--settle`, `--verify`, `act batch` (plus `@N` aliases, which are **Android-only** — the outline cache is not ported to the iOS host, and `Render.swift` says so in place). Real HID on Android and the iOS simulator; in-process activation on iOS devices |
| **Evidence** | Action traces (before/after snapshots + screenshots + a ranked, self-describing diff), recorded by default; `trace log` digest, `replay gif`, session timeline, the absence vocabulary (`window: UNFOCUSED`, `dom:unavailable`, `dom:unsupported-kernel`, `pixels:unavailable`, `screencap:blank`, `occluded-by:*`, `scroll:*`) |
| **Network** | `reticle serve` capture lane on Loom's `ProxyEngine`, HTTPS MITM with CA issuance, session-scoped traffic rules (`mock`/`block`/`mapRemote`/`passthrough` + modifiers), flow replay + diff. Android and iOS (simulator and device) |
| **Panel** | Localhost read-only evidence panel: traces, artifacts, network cards with filters and rule grouping, "copy as rule". Display-only by design |
| **Protocol** | JSON Schema (2020-12) authoritative in `reticle-protocol/`, with golden fixtures; Kotlin and Swift are hand-written implementations pinned to it from both sides |
| **Distribution** | Swift host + native (GraalVM) Kotlin helper, shipped as a prebuilt release; Claude Code / Cursor plugin manifests in lockstep |
| **Coverage** | `scripts/e2e-android.sh` and `scripts/e2e-ios.sh` drive every scenario against a real device/emulator, each step asserting an observable side effect; `scripts/e2e-proxy.sh` guards the capture lane in CI |

`docs/architecture.md` carries the operational detail for all of the above.

**Platform parity.** Android and iOS are at effective parity for
observe / drive / capture + evidence, across simulator and device: the iOS agent,
host platform, WebView bridge, action traces and the capture proxy all ship, and
the linked-agent real-device path is validated on an iPhone 13 Pro Max / iOS 26
(`scripts/e2e-ios-device.sh` — observation, `activate`, `mutate`, trace evidence
over the USB tunnel, plus a decrypted HTTPS event with the proxy bound to the LAN).
The one structural gap left is **real-device HID input** (item 5). HarmonyOS is
unstarted and unvalidated — see Deferred.

---

## What's left

Ordered by leverage. Sizes are rough: **S** ≈ a day, **M** ≈ a few days, **L** ≈ a
project. Each item also carries how well its problem is established: *measured*
(reproduced on a device), *by construction* (the code cannot do otherwise), or
nothing at all — and an item with nothing needs that step before it is built
(see [the cause-check rule](#decisions-of-record)).

### 1. Long-session hygiene — S, by construction

E2E runs are long, and the one known leak bites exactly there.

- **`network-bodies/` grows without eviction.** A body artifact is written per flow
  and never dropped, so a long verification session leaks disk. Eviction must be
  coupled to event-ring eviction: a body is evidence a live event still references,
  so it cannot be dropped underneath it.

### 2. Test coverage where a bug has already hidden — M

The audit's biggest gap, and not theoretical: the `nativeID` capture-vs-resolve
mismatch hid in exactly this blind spot.

- **The in-app Android agent has zero unit tests.** `MutationEngine` (selector
  resolution), `SnapshotCapture` (the testId chain), `ReticleReflect`, and the
  WebView/Compose bridges are all untested, and the pure logic among them is
  JVM/Robolectric-testable.
- **Inject orchestration is untested.** `JdwpClientTest` covers only handshake and
  id-size negotiation; `JdwpClient.inject()`'s breakpoint/InvokeMethod sequence and
  `Injector.inject`'s ordering + dead-zone retry are proven only on a device.
- **Swift: the rule → Loom `translate*()` layer and the HTTP routes.** The
  translation layer (path→regex lifting, priority ordering, no-op dropping) is the
  most error-prone single point in the lane; `rules` and `flows/:id/replay` have no
  route-level regression net.

### 3. Evidence assembly products — M each, nothing built

The primitives exist and the agent assembles them by hand. Each of these packages
them into something a human consumes directly; all three emit magnitudes, never
grades. Do **A1 → A2** (A4 already landed as `replay gif`; A3 was dropped as
specified — see below).

- **A1 — PR evidence bot (`reticle review`).** Read a diff → drive a deterministic
  flow to the affected screens → assemble trace + compact diff + network events +
  screenshots into a PR comment. Reuses `act batch`, `--trace-output`, the session
  timeline.
- **A2 — visual regression (`reticle diff visual`).** Pixel-diff screenshots
  between builds with a change-region overlay. Complements structural diff:
  structural says "text/state changed", pixel says "layout/render drifted". The
  threshold is a hint, not a verdict.
- **A3 — design-fidelity evidence — DROPPED as specified; the capability half
  landed as `ui style`.** It was to align a design frame's boxes with live node
  rects and emit per-region deltas. That is a verdict wearing an observation's
  clothes, and the "no letter grade" caveat only blocked the third of three ways
  in: reading the design imports an external truth and makes Reticle the arbiter
  of correct; a delta needs a tolerance, which is policy; and skipping the status
  bar needs an exemption list, which is domain policy. All three belong to the
  consumer. What is genuinely unguessable from outside — the values, the units they
  are measured in, and which properties no channel can read — is now `ui style`
  (`StyleObservation`), and Reticle does not care whether the caller compares it
  against a design frame, a previous build, or a second device.

  Two consequences worth keeping written down. **A `reticle diff responsive`** was
  considered and rejected for the same reason even though it imports no external
  truth: classifying a width as "should scale proportionally" versus "should stay
  a fixed dp" IS the design intent. `ui style` instead emits every length in raw
  units, dp and (for text) sp plus a share of the screen, and the consumer picks
  which one it expects to hold constant across devices. And **A2 stands** — it
  compares two pictures Reticle took itself, invents no truth, and its threshold is
  already documented as a hint; it is a pixel-evidence product, not a fidelity
  verdict.
- **A5 — navigation / coverage map (`reticle map`).** Fold `ui outline` + trace
  transitions into "screen → reachable path", positioned strictly as a coverage aid
  ("what no flow touches yet"), never a verification path. Lowest priority.

### 4. Cross-signal correlation — M, the gap a verify pass actually feels

The session timeline unifies UI action + network + screenshot, but the two
questions a verification step asks right after a tap — *did the right analytics
event fire?* and *did anything crash?* — live in separately-queried tools
(`sensors-query`, `sentry-query`). The agent hand-correlates across them today.
Folding analytics/error signals in as evidence sources needs an orchestration
layer, not a new capture mechanism.

### 5. iOS real-device input cliff — L, quantify before building

A real device has only `act activate` (selector-driven); point taps, complex
gestures and keyboard `type` need a booted simulator's HID surface, so any
real-device step without a stable selector is uncovered. Closing it means
XCUITest/WDA or CoreDevice — a real project. **First measure how many real-device
actions `activate` genuinely cannot cover**; the cause-check rule applies.

### 6. Phase remainders — S–L, additive

- **Live object inspection + layout diagnostics (`ui audit`)** — L. Generalize the
  reflection behind `mutate` into runtime class metadata and constraint inspection.
  Honest ceiling as above: reflectable metadata + reachable graph only.
- **WebView L2 (semantic enrichment)** — S. ARIA role + accessible name from the
  existing traversal script, aligned with the semantic tree. L0/L1 are landed.
- **Selector-resolution sink-down** — M. Selector resolution is the last derivation
  still host-side; moving it into the agent completes the thin-client boundary and
  tightens single-capture consistency.
- **Typed schema for the remaining event families** — S. `network.*` payloads are
  schema'd and pinned from both languages; action/runtime payloads are not.
- **Rule matcher predicates for headers/body** — S, *on demand only*. Add when a
  concrete case appears, not before.

### 7. Security-evidence lane — M each, nothing built

Reticle is a **defensive evidence engine** here: observe, drive, capture. Out of
scope permanently, because it crosses the no-hook line: pinning bypass, runtime
CA-trust injection, capture-pipeline hooking / virtual-camera injection, binary
reversing. Do **B2** first — it fits the deterministic-drive + mock shape best.

- **B2 — risk-control flow regression harness.** Drive liveness / face-upload /
  device-check flows, capture their calls to external verification services, and
  use session rules to mock different external verdicts (trusted / untrusted /
  degraded) so each client branch can be exercised deterministically.
- **B1 — sensitive-data-in-transit evidence.** On the existing MITM lane: plaintext
  flags, annotated positions of suspected sensitive fields (configurable patterns),
  and an honest "opaque, not decrypted" annotation when a tunnel cannot be read.
- **B3 — client security-posture snapshot (observe-only).** Debuggable flag,
  user-CA/network-security-config annotations, WebView JS + mixed content, and the
  component-exposure surface visible through reflection. Needs the `ui audit`
  capability from item 6.

### 8. Docs debt — S

Both prior items are closed (README parity restored in both directions, and
`connectWithHandshake` documented at the function). What remains is structural:

- **Two full READMEs stay a standing cost.** Parity was restored twice now, in both
  directions, which is the signal: a feature landing has to be written up twice or
  one side silently loses it. If it drifts a third time, cut the Chinese README to
  an orientation page that points at the English one for depth rather than
  re-syncing 400 lines again.

### Open flakes (software-GPU emulator)

- A DOM assertion taken from a single snapshot while `lottie-web` animates: the
  750ms `evaluateJavascript` budget lapses and the whole DOM folds away. Mitigated
  by polling; the underlying budget question is open.
- The native-Lottie dialog occasionally not appearing within the 60s `wait_compact`
  budget — seen twice on 2026-07-25 and **not reproducible in isolation** (4/4 green
  by hand, with the trigger's rect stable from the first capture, so it is not the
  `tap --settle` class). Rather than guess, `wait_compact` now prints its last
  observation on timeout, so the next occurrence says whether the tap never landed
  or the capture degraded under animation load.

- **`scripts/e2e-ios.sh` assumes warm app state.** Measured 2026-07-29 on a
  freshly created simulator: the sample app opens on the Login screen, so the
  script's first navigation (`act activate --test-id scenario.checkout`) finds no
  such node and the run stops there. On a simulator that has been used before, the
  app is already past login and the suite passes — i.e. the suite is only
  reproducible on a warm device, which is the opposite of what a fixture should
  be. Not a product defect (both paths behave correctly), and the obvious fix is
  constrained: logging in early must not TYPE, because the first HID keyboard event
  latches the simulator's hardware-keyboard state and would destroy the LOGIN
  section's own keyboard assertions later in the same run (see docs/boundaries.md).

### Deferred — parked until a trigger arrives

- **HarmonyOS feasibility probe.** The HarmonyOS seams (`hdc` forward/input, a
  debug-injection channel) are paper placeholders with **zero validation**.
  *Trigger:* before HarmonyOS enters any committed plan, spend a short spike to
  confirm the seams exist. Until then it stays marked `est.`/`TBD`, not promised.
- **Web panel reverse-drive.** The panel is display-only over one-way SSE. Letting
  the browser drive the app forces a bidirectional transport (WebSocket) plus real
  front-end work. *Trigger:* decide before any change to the panel transport, so
  SSE-vs-WebSocket is not reworked twice.
- **Protocol codegen unification.** Kotlin and Swift models / renderers / selector /
  trace-diff / WebView scripts are hand-written 1:1, drift-guarded by tests against
  the shared schema. Codegen is a large project with slow payoff. *Trigger:* a drift
  bug that the schema tests fail to catch.

  **The trigger has fired once, and was answered with a fixture instead.** Selector
  resolution had drifted seven ways between the two hand-written host-side
  resolvers — including one that made a lookup nondeterministic per process on the
  Swift side — and no schema test could have caught any of them, because none of it
  is wire shape. The fix was `selector-resolution.cases.json`, a shared decision
  table both suites read, which is the same device `wait-classification.cases.json`
  already was. That is the cheaper answer while the drifting surfaces are *behaviour
  tables* rather than *models*. Revisit codegen if a drift appears in the models
  themselves, where a fixture cannot describe the contract.

---

## Decisions of record

Settled. Recorded with the reasoning so they are not silently re-litigated.

**The protocol is the spine, not the code.** Agent and host speak loopback
HTTP + JSON. `reticle-protocol/` holds authoritative JSON Schema (2020-12) +
golden fixtures + `events.md` (the daemon event envelope and taxonomy) +
`helper-rpc.md`. Kotlin (`reticle-core`) and Swift (`reticle-swift`) are
**hand-written implementations verified against the schema from both sides** —
kept hand-written for their doc comments and sealed-hierarchy serialization, which
codegen handles poorly. A future greenfield platform may codegen from the same
schema; generate-vs-hand-write is a per-platform choice.

**Only three seams are platform-specific**, and the HTTP transport is already
platform-neutral:

| Seam | Android | iOS | HarmonyOS (est., unvalidated) |
| --- | --- | --- | --- |
| Device control / transport | `Adb` | `xcrun simctl` + CoreSimulator | `hdc` |
| Injection | JDWP + payload dex | DYLD constructor (sim) / linked framework (device) | TBD |
| Input synthesis | `adb input` | private CoreSimulator HID | `hdc input` |

Reservation means **interfaces, not stubs** — no empty per-platform modules. Only
the agent is genuinely platform-specific and gets its own build (AAR / SwiftPM /
HAP); `reticle-agent/` is a grouping directory that must never own a
`build.gradle`.

**The host is a thin client; derivation lives in the agent.** Capture-derived views
(`SemanticTree.build`, `CompactObservation.from`) are computed in-process and
returned as finished JSON. `PortMap.derivePort` is the deliberate exception — the
host needs the port *before* it can reach the agent, so it is a protocol rule
implemented identically on both ends. Selector resolution is the last piece still
host-side (item 6).

**Swift host + per-platform helpers — shipped.** The host program (CLI + daemon +
panel, one process) is Swift; Android's device dirty-work stays Kotlin behind an
RPC seam, shipped as a no-JDK GraalVM native `reticle-helper`. Why not a full
rewrite: JDWP injection is irreducibly host-side (the agent is the *result* of
injection, not a precondition) and irreducibly JVM-natural, and every fix in its
history is a hard-won ART/dexopt edge case. A helper exists **only** where a
platform's dirty-work lives outside the host's ecosystem — Android warrants one,
iOS does not (simctl/DYLD are native to a Swift host). The trade accepted: two
resident processes and a cross-process boundary on hot Android calls, in exchange
for eliminating the JDWP-rewrite risk entirely.

**The daemon owns all long-lived state.** One-shot commands still work standalone;
when `reticle serve` is up they additionally publish events to it. Sessions tie
device + app + time window into one timeline. Bounded in-memory ring + JSONL
persistence; large bodies and screenshots spill to the session dir and are
referenced by `refs`, never inlined. Live feed is SSE + REST — WebSocket is
reserved for reverse-drive, which is deferred.

**The capture engine sits behind one sink.** `NetworkEventSink` (emit +
sessionDirectory) is the lane's only view of the host, so the engine is swappable
by editing one target. The engine question is settled: Loom's `ProxyEngine`,
consumed as an SPM library, run loopback with `persistFlows: false` — transport,
MITM and CA are Loom's; storage and normalization are Reticle's.

**Capture proxy stops at the host (L1).** HTTP plaintext freely; HTTPS only where
the app trusts the local CA; pinning defeats it and is *reported*, not bypassed. An
"L2 agent-assisted" mode (injecting CA trust or neutralizing pinning at runtime)
was considered and **rejected** to keep the no-hook guarantee.

**WebView DOM is the Compose bridge again, not a new mechanism.** DOM elements
merge into the same flat node map as `NodeKind.domNode`, so compact / tree /
selector / tap reuse unchanged. Two things Compose does not have: the read is
async and cross-boundary (`evaluateJavascript`, latched with a bounded timeout),
and coordinates must be folded from CSS px to screen px — the protocol pins that a
`domNode.frame` is *already* in screen space. Tiers degrade honestly: L0 opaque
leaf → L1 DOM structure (landed) → L2 semantic (item 6). Chrome Custom Tabs / TWA
are a separate process and out of scope.

**Feature parity requires a cause check.** Before building a capability on platform
B because platform A has it, prove the *cause* exists on B. This rule is what kept
the boundary sweep honest — several "gaps" turned out to be different problems, and
one turned out not to exist.

---

## Investigated and dropped

**`act wait --for <appears|gone|stable|enabled|network-idle>`** — dropped on
reliability grounds after a code-level audit. A wait that silently returns a wrong
answer is worse than no wait, and the ground truth it would poll cannot support a
reliable one:

- `isVisible` is a weak, platform-divergent proxy (Android: `visibility==VISIBLE &&
  w>0 && h>0`, no ancestor chain, no on-screen test; iOS: chained
  `parentVisible && !isHidden && alpha>0.01`), and **neither raw node carries
  occlusion** — occlusion is computed only in the compact layer. So `appears` could
  report visible for a node a tap would miss;
- refs are minted per capture, so `ref`/`alias` cannot identify the same node across
  polls;
- selector resolution collapses to the first match, which can be a *different* node
  across polls, breaking any before/after comparison;
- `stable` cannot see transform/alpha animation (only layout bounds), and per-poll
  full snapshots perturb the animation being observed.

The only reliable definition of `appears` is "a tap dispatched now would land here",
which needs backbone visibility unification, not a poll layer. `tap --settle`
(landed) is the narrow, honest slice of this: same resolution path as the tap
itself, position only, and it says so — see the sweep record below for the measured
case where position-stability is *not* enough.

**L2 agent-assisted CA trust / pinning neutralization** — rejected; see the capture
proxy decision above.

**Heap instance enumeration** — out of scope by construction; `am dumpheap`
analyzed offline is the honest path.

---

## Completed programme: the boundary-case sweep (2026-07-25)

A prioritised sweep of "cases the tool cannot yet cover", one PR per point, with the
same discipline each time: **prove the cause on a device first**, fix only what the
evidence justifies, then pin it with an assertion in both e2e suites. That order
paid for itself — half the points were real defects failing *closed* (silently
returning nothing), and two "fixes" broke something else that the suites caught
immediately.

Fifteen points, PRs #107–#121, all merged. The durable output beyond the individual
fixes: the **absence vocabulary** every capture now speaks, and the **Honest
boundaries** table in `docs/boundaries.md` — which is where the next such case
gets recorded.

| Point | Verified cause | Outcome |
| --- | --- | --- |
| Region channels | `a11yVirtual` probed virtual ids `0 until childCount`, but the ids are the APP's (`ExploreByTouchHelper` may use stable domain ids) -> zero regions; `touchDelegate` read `TouchDelegate.mBounds`, which the platform blocks (`api=max-target-o`) for any modern target -> channel dead on every real app | Both fixed (androidx helper route + public `getTouchDelegateInfo()`); iOS learned the second `UIAccessibilityContainer` convention; `--region <source>` addresses label-less channels |
| Compose semantics | Bridge worked but had **zero** coverage (no Compose anywhere in the repo) | Compose scenario + e2e: testTag tap, `type` into a composable field, Compose `Dialog` as its own window, `AndroidView` interop |
| Compose text links | A `Text` with two `LinkAnnotation`s = ONE node, no regions, no char grid (a `ClickableSpan` row decomposes fine) | `ComposeTextRegions`: link ranges from the semantics config + geometry from the `GetTextLayoutResult` action |
| Same-origin iframe | Piercing and page-offset were CORRECT; nothing asserted them (iOS only checked JS activation, which passes with a wrong rect) | Coordinate-tap assertions on both platforms |
| Off-screen list rows | A recycling/lazy list binds only its visible window: rows 0-14 of 60 (Android), 0-12 (iOS). Row 40 has no node, frame or selector | `Node.scroll` evidence (+ `scroll:up,down` in compact, + scroll hints in selector-miss diagnostics) and `act scroll-to` |
| Popup windows | `PopupWindow` / `Spinner` dropdown / `PopupMenu` captured correctly — but their rows share one resource id, so nothing could single one out | `--label` selector (exact -> substring, topmost window that has a match, **ambiguity is an error**) |
| Blocked DOM read | Degrade was correct (~1s, opaque node) but SILENT: "no DOM nodes" was indistinguishable from "empty page" | `dom:unavailable` marker on the host node, both platforms |
| iOS window occlusion | Every `UIWindow` was `kind = .view`, so window-vs-window occlusion had NEVER fired on iOS — an overlay window left everything beneath it looking tappable | `kind = .window`, minus keyboard host windows (screen-sized, they marked the whole screen occluded) |
| Out-of-process windows | With Android's permission prompt up, `mCurrentFocus` was the permission controller while the capture still listed every control as `tappable`. The in-process **screenshot** is blind to it too | `screen.windowFocused` + `window: UNFOCUSED …` leading the compact; permission scenario on both platforms |
| Tap on a moving target | Resolution and dispatch are two steps: a `PopupMenu` row captured mid-slide was at y=1396, the tap resolved y=1474, the menu rested at y=1612 — `--label "Delete item"` fired "Menu: Rename" (1 run in 5). The iOS shape is NOT this: a `UIAlertController`'s AX frame is final from the first capture while a tap right after `activate` never lands — an in-place transform animation, invisible to any position signal | `act tap --settle` (+ `--settle-timeout`): re-resolve until the point repeats, then dispatch, reporting `settled` honestly. Needs a selector; a raw `--point` is refused. The iOS suite pins the distinction — settle reports `settled=true` for the alert and the delay stays |
| SwiftUI Text links | A markdown `Text` is ONE accessibility element with one label: no `UILabel`, no `.link` run, no child element (probed: 0), no element count, no custom actions, no usable rotor, no `_accessibility*` accessor. `accessibilityAttributedLabel` DOES carry `UIAccessibilityTokenLink` runs + per-run font tokens | `SwiftUITextRegions`: re-lay the runs out with their own fonts inside the element's screen frame -> per-link `span` regions + char grid. Geometry is reconstructed, so the suite asserts by CONSEQUENCE — tap each rect, check which URL `openURL` received |
| Screenshot degrade | The two paths are exact complements, not "in-process misses both": a `SurfaceView` is a transparent hole (rgba 0,0,0,0) in-process but magenta in `screencap`, while `FLAG_SECURE` blanks the DEVICE capture and leaves the in-process one untouched. iOS has a third shape: the keyboard host window refuses to render into a borrowed context, and the capture already skipped it — silently | `pixels:unavailable` / `screencap:blank` + a `degraded:` line on `ui screenshot` naming what THIS picture is missing and which path would show it. Both suites assert the labels AND the pixels behind them |
| Third-party WebView kernels | Confirmed by construction: the bridge is typed on `android.webkit.WebView`, so a kernel that only calls itself a WebView gets no DOM at any level — indistinguishable from an empty page | Reported, not adapted (a reflective adapter cannot be verified without a real kernel sample): `dom:unsupported-kernel` + `custom.domKernel`, a `--css` miss that explains the wall, and a stand-in beside a real WebView so the contrast is asserted |
| Structural boundaries | Several were assumed rather than measured. Writing them down forced two checks: a CLOSED shadow root drops only its content (the host element is captured at its own rect), and the cross-origin case genuinely cannot be exercised offline | The **Honest boundaries** table in `docs/boundaries.md`, each case beside the evidence emitted for it and the scenario that pins it, with "not exercised" written where true. Agent-facing half in the skill |
| iOS focus evidence, asserted | Unassertable for two measured reasons: the prompt could not be **re-armed** (`simctl privacy … reset notifications` fails outright) and an open alert could not be **answered** from the host, while a stuck one silently swallows every later HID tap | Re-arm by re-INSTALLING the bundle; answer with a coordinate HID tap at the alert's fixed layout position (~57% height, ~32% deny / ~68% allow — no text read) inside an answer→retry→re-check loop, in a section that runs LAST |

Self-inflicted bugs the suites caught, worth remembering as failure shapes:
`act scroll-to` first flicked (a flinging list left the reported point stale by the
next command — now it drags slowly and confirms `settled`); it picked the largest
scrollable *anywhere*, which was a background window's page scroller; it re-chose
direction every iteration, so an absent selector ping-ponged at the list's end. And
the sample's own home list had outgrown one screen, so its last rows were clipped
and genuinely untappable — a resolved tap landed on the system navigation bar.
