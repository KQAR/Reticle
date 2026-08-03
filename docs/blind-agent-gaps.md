# Blind-agent gaps

Where Reticle still forces an agent to look at pixels.

Reticle's contract is that a model with **no visual capability** can inspect and
drive a running app end to end. Every place that contract breaks — every step
where the only way forward was to read a screenshot with human eyes and convert
pixels into `act tap --point` — is a defect, not a limitation.

This file is deliberately **not** [boundaries.md](boundaries.md). That file lists
things no in-process observer can reach, each one already emitting evidence that
names itself; the rule there is *an unreachable thing must produce evidence naming
itself, never silence*. Everything below is the opposite shape: the data is
reachable, or the failure is reportable, and Reticle currently does neither. A row
here is a bug with a fix, not a fact to be documented.

## Where this came from

One end-to-end run of a multi-step onboarding flow in a hybrid Android app —
native shell, React Native screens, WebView forms, and a third-party
**cross-origin iframe** widget — driven entirely through the CLI. Measured over
that run:

| | |
| --- | --- |
| Actions recorded | 92 |
| Taps | ~50 |
| Taps that resolved through a selector | 27 |
| **Taps that fell back to `--point`** | **23** |
| **Screenshots that had to be read visually to make progress** | **13** |

Nearly half of all taps were pixel arithmetic. A blind model would have stalled at
the first of them.

Two things this run was NOT: it was not a source-instrumented fixture (the app
under test carries no `testID`/`nativeID` on its RN screens, which is the ordinary
case for an app one does not own), and it was not a degraded runtime — `status`
reported `runtime: healthy` throughout and the DOM bridge was live the whole time.
Every gap below happened with everything working.

## A. Gaps that force `act tap --point`

| Gap | What was measured | Why it forces pixels | Fix shape |
| --- | --- | --- | --- |
| ~~**An unselected dropdown has no node at all**~~ **(fixed)** | Five select controls on one screen. Before selection each is present ONLY as `label "…" [102,596 284x57]` — no `button`, no `select`, no `combobox`, nothing marked `tappable`. After a value is chosen the same control materialises as `button "<selected value>"` | The agent reads five labels and has no executable next step. The control's trigger region exists on screen and in the DOM; it is simply absent from the projection | Emit the trigger as an interactive node in its EMPTY state, with `role=combobox` + `expanded=false`. Failing that, mark the `label` itself `tappable` and point it at the trigger rect |
| ~~**`act type` on a DOM input is refused by the focus guard**~~ **(fixed)** | `error: resolved 'semantic:ref' -> rNNN but the tap did not focus a text field (focus is on an unrelated node). Typing now would send the text into whatever holds focus while reporting success, so it is refused.` Hit on 7 separate fields across 3 screens | The guard is correct on the View channel and **wrong on the DOM channel**: Android focus legitimately sits on the host `WebView` while the caret is in a DOM input, so the guard can never be satisfied. The only way through is `tap --point` followed by a selector-less `type` — i.e. abandoning semantic targeting for the whole form | Treat `focusLanded=ancestor` as landed when the resolved target is a DOM node (this is already the documented meaning of `ancestor`), or read `document.activeElement` over the bridge and compare it to the target |
| **A cross-origin iframe's contents are empty AND unannounced** | A third-party widget captured as `rNNN iframe "<title>" [57,624 964x1689]` with `childRefs = None`. Four consecutive steps inside it — pick an item from a list, tick a consent, advance twice — were done by measuring pixels off screenshots | The emptiness is a real boundary ([boundaries.md](boundaries.md) row *Cross-origin iframes*) and is not the defect. The defect is that it is **silent**: an empty iframe is indistinguishable from one that has not finished loading, so the agent has no cue to stop retrying and switch tactics, and no statement that coordinates are the only remaining path | Emit `iframe:cross-origin` on the compact line, and have `act` fail against a selector inside that subtree with a message that names the wall and states the coordinate fallback explicitly |
| **A DOM rect that was correct at capture time, tapped after a relayout** *(cause revised — see below)* | An `input` reported at frame centre `(653,1540)`; a coordinate tap there changed its computed background and transform but did not complete the step, while a tap at `(748,1678)`, measured off a screenshot, did | Originally filed as a broken coordinate fold for a non-first WebView. **Two candidate mechanisms have since been falsified with fixtures** (below), and the reading consistent with the trace is a stale rect across a relayout — which Reticle already handles via `--settle` / `rectMoved`, and which that run never used on those taps | Nothing to fix until it is reproduced. What the investigation DID buy is coverage: `scaled` and `nested-webviews` fixtures now pin the two mechanisms that were suspected, so if either ever does break it fails a test instead of a flow |

## B. Gaps that force reading a screenshot

None of these are about tapping — they are states an agent must know to decide
what to do next, and none of them are currently answerable from the tree.

| Gap | What was measured | Fix shape |
| --- | --- | --- |
| ~~**Checked state is unreadable**~~ **(fixed)** | Nodes projected as `role: checkbox` carry no `checked` property. Separately, `{"domTag": "input", "domInputType": "checkbox"}` is projected as **`role: textField`** — the input-type is captured and then ignored by the role mapping | Add `checked` to the node contract. Fix the DOM role mapping to consume `domInputType` (`checkbox`, `radio`, `submit`, `button`, `range`, …) — a submit `input` currently reads as a text field too |
| ~~**`placeholder` and value are indistinguishable**~~ **(fixed)** | A field showing grey placeholder text projects as `textField "test1"`, identical to the same field holding the typed value `test1`. `act type` says so itself: `textReadback=unavailable:dom-input-value-not-separable-from-placeholder` | Capture `placeholder` as its own property and keep `text` for the value. This also removes the readback excuse above |
| ~~**Truncated input is reported as unreadable, not as truncated**~~ **(fixed)** | `--text "00-001"` landed as `00-1`. The result was `chars=6 textLanded=unreadable textReadback=unavailable:no-text-field-node`. A `ui compact` moments later read the field back correctly as `"00-1"` — so the value WAS readable, the readback merely ran before the DOM re-rendered | Because DOM readback always returns `unavailable`, the `partial → clipboard retry` recovery that protects the View channel **never fires for web forms**. Retry the readback after a settle, then let the existing recovery path do its job |
| ~~**`act type` on a DOM input reports success with the keyboard down**~~ **(fixed)** | One `type` returned `chars=5 gesture=type keyboardVisible=0 … textLanded=unreadable`. Nothing landed; the page then raised its own native validation. On the View channel this same situation fails with `focusLanded=none` | Apply the same refusal on the DOM channel. `keyboardVisible=0` plus an unreadable readback is not a success — it is an unverifiable dispatch and should be reported as one |
| ~~**A validation error is not tied to the field it belongs to**~~ **(fixed)** | An error string is present as an ordinary sibling `div`. Nothing in the tree associates it with the input above it, and nothing marks that input invalid | Project `aria-describedby` / `aria-invalid`, or infer a `describedBy` ref from the DOM relationship and mark the field `invalid=true` |
| ~~**Attributes that carry a form's meaning are not captured**~~ **(partly fixed)** | A DOM input's captured properties are `domTag`, `domId`, `domClass`, `domCssSelector`, `domInputType`, `domScaleX`, `domScaleY`. `id` IS captured and surfaced as `testId` (so `--test-id` works when the app sets one). **`placeholder`, `name`, `aria-label`, `aria-labelledby` are not.** On a component-framework form whose inputs carry no `id`, five empty fields project as five identical `textField [105,YYY 880x57]` lines distinguishable only by y-coordinate | Capture `name`, `placeholder`, `aria-label`, `aria-labelledby`. These are the only semantic handles such a form has |
| **Which page is in front is not stated** | Two `ViewPager` pages, and separately two live `WebView`s, are flattened into one projection ordered by y — a foreground node and a background node can be adjacent lines with nothing distinguishing them. `--window top` does not help: they share one window | Mark background-page / background-WebView subtrees (`offscreen`, `inactive`), or let a `--window`-style scope narrow to the active page within a window |

## C. Gaps that make an existing selector unusable

| Gap | What was measured | Fix shape |
| --- | --- | --- |
| ~~**`--css` does not evaluate CSS**~~ **(fixed)** | `--css 'input.some-class'` → `no matching node`, on a page containing exactly such inputs. Matching is a string comparison against each node's captured `domCssSelector` full path, so only a verbatim full path can ever match — no descendant combinator, no class-only, no attribute selector. The documented example form (`--css '#pay'`) does not work on a real page unless that literal string is the captured path | Evaluate the selector in the page over the DOM bridge (`querySelectorAll`) and map results back to refs |
| ~~**A `--css` miss dumps unranked full paths**~~ **(fixed)** | A single miss printed 12 candidates, each a complete ancestor chain, ~6 KB total — and the candidates were unrelated nodes (decorative SVG elements, list items of an animated counter), not near-misses on the requested selector | Rank candidates by similarity to the query, cap the count, and print a shortened form (last 2–3 segments) |
| **Off-screen DOM nodes count as visible for `--label`** | An animated numeric counter contributes ~40 `li` nodes, most clipped out of the viewport by an ancestor's overflow (frames at negative y, or far below the screen). Selecting a numeric option elsewhere on the page failed with `label '5' matched 4 visible nodes` — three of them clipped counter digits | Exclude nodes clipped out of their scroll container from `--label` candidacy, and from `ui outline` numbering |
| **`ui outline` numbers the whole scrollable tree** | On a 1080x2412 screen, `outline` emitted 135 aliases, the last at `y=10800` — roughly 15 were actually on screen. The skill documentation describes it as printing *visible* labelled/interactive nodes | Restrict to the viewport by default; offer `--all` for the current behaviour. This also makes `@N` numbering stable enough to act on |

## D. Reporting gaps

| Gap | What was measured | Fix shape |
| --- | --- | --- |
| **`--verify` reads like a failure after a navigation** | `act tap --resource-id <id> --verify` printed `verify @<id>: no change` while the same action's trace recorded `101 change(s)` — the screen had been replaced entirely | Say what was compared. When the target node is gone or the screen changed wholesale, report that instead of `no change` |
| **`--point` is silent about why it was needed** | 23 of ~50 taps were `--point`. Nothing in any of those results notes that no selector was available, or why | Have `act … --point` emit `warning: no semantic selector covers this region` with the reason (cross-origin iframe / no interactive node captured / DOM subtree unreadable). The warning is what converts a silent degradation into a filed gap |
| **There is no way to ask "how much of this screen is unreachable?"** | The only way to discover the gaps above was to run a real flow and notice the fallbacks by hand | Add a coverage check (`ui coverage`) reporting the share of visible, interactive-looking screen area with no addressable node over it. That number is the direct measure of the blind-agent contract |

## Progress

A row is struck through once its fix has landed WITH a test that would catch the
regression — not when a patch exists. `scenario` names below are sections of
`scripts/e2e-android.sh`.

| Landed | What closed | Pinned by |
| --- | --- | --- |
| `--css` | Matched structurally against the captured tree (type / `#id` / `.class` / compounds, descendant / child / `>>>`), with the captured-path equality kept as a first attempt; unsupported constructs refused **by name** rather than answered as a miss; a miss lists only candidates sharing part of the query, by their shortest handle. The resolver and the helper's `findNode` had each grown their own copy of the rule — both now call one matcher | 7 new cases in `reticle-protocol/fixtures/selector-resolution.cases.json`, so Android and iOS cannot drift (the Swift side was caught swallowing the refusal into a miss); `SelectorDiagnosticsTest`; a **CSS SELECTORS** e2e section |
| Framework-built triggers | A widget `role` (`combobox`/`option`/`treeitem`/…), `aria-haspopup`, `aria-expanded` and a starting `cursor: pointer` all make a node `tappable`; `expanded` is a first-class tri-state and `popup:<kind>` says an empty subtree is expected; `--label` resolves a caption/control pair to the actionable one | `FormSemanticsTest` (disclosure state, caption-vs-control, and that two actionable matches still refuse); the **WEB FORM SEMANTICS** e2e opens a div-built dropdown by label, asserts its options materialise, picks one and reads the committed value back — no coordinates |
| `act type` into web forms | The read-back applies to DOM inputs (it was refused for every one of them); an empty input reads as empty rather than unreadable, and a non-input DOM node says so precisely; a DOM field is re-read up to 3× so an async page handler is not mistaken for "no text channel". `--label` is a selector `type` TAPS — it was missing from the list, so `act type --label …` typed into whatever already held focus and reported success. `--label` also matches a `placeholder`, which for an empty input on such a form is the only text on screen | The **WEB FORM SEMANTICS** e2e section fills the whole form through `--label` with no coordinates, asserting `textLanded=exact` and the field's own text; `TypeReadbackTest` covers the DOM cases |
| DOM input semantics | An `<input>`'s type is its role (`checkbox`/`radio`/`slider`/`button`); `placeholder` is its own field, never the value; `checked` is a first-class tri-state on `Node` (`null` = not checkable) sourced from Android `Checkable`, Compose `ToggleableState`/`Selected`, DOM `checked` and `aria-checked`/`aria-pressed`; `aria-invalid` + `aria-describedby` project as ` invalid:"<message>"`; `name` and the `aria-labelledby`-resolved accessible name are captured | `FormSemanticsTest` (Kotlin) + `FormSemanticsTests` (Swift) — the projection contract on both platforms; the **WEB FORM SEMANTICS** section of `scripts/e2e-android.sh` against a new `form` fixture with no ids, no testids and no values |

Still open on the same row: `placeholder`/`name`/`aria-*` are captured but a form
whose inputs set *none* of them still has only its rect. That is a page with no
semantic layer at all, and no capture change can invent one.

### A note on the coordinate row, and on filing causes

The nested-WebView row above was filed with a cause attached — "the fold drops a
non-first WebView's container offset" — and that cause was wrong. Two mechanisms
were tested against real fixtures on a device and both came back clean:

- **Zoom.** A WebView at `setInitialScale(130)`: the layout viewport does not change
  under zoom, so a page-to-device scale derived from `innerWidth` looked like it had
  to be off by the zoom factor. It is not — `frameWidth / innerWidth` already
  absorbs it, and a coordinate tap on a target 300 CSS-px down the page lands.
- **A second, offset WebView.** Two live WebViews in one window, the overlay inset
  24dp left and 220dp down, with a target 220 CSS-px into its own page. Both the
  container offset and the page offset are accumulated correctly and a coordinate
  tap fires the overlay's own `onclick`, not the backdrop's.

What remains consistent with the original trace is an ordinary stale rect: the
screenshot the `(748,1678)` point came from was taken several actions before the
snapshot the `(653,1540)` rect came from, with a tap in between that could relayout
the card. Reticle has an answer for that (`--settle`, and `rectMoved` when the
first read was stale); the run simply did not use it there.

The row stays in this file — the observation was real and is not explained — but
with the cause withdrawn. **A gap is filed on what was measured; a cause is a
separate claim and has to earn its own evidence.** Two fixtures are the residue of
getting that wrong here, and they are worth keeping: every other web fixture renders
at 1:1 in a single full-bleed WebView, where wrong arithmetic and right arithmetic
agree.

## The rule

`ui screenshot` exists as an honest degraded mode. In this run it was the
**primary targeting mechanism**. Any step that can only be completed with
`--point` should be treated as a coverage gap Reticle reports on itself — never as
an acceptable path that an agent quietly falls back to.
