# Changelog

## Unreleased

- **iOS `ui node --css` refuses unsupported syntax instead of reporting a miss.** The
  matcher throws for constructs it does not implement, because "not understood" and
  "no such element" lead to opposite next actions — but the iOS node lookup wrapped
  each per-node match in `try?`, so the refusal was swallowed and `--css 'div:hover'`
  answered `no node matched selector css=div:hover` while the Android helper named the
  pseudo-class. The lookup now goes through `CssSelectorMatch.find`, which also puts
  document order in one place. A genuine miss is still a miss. Found by the iOS e2e
  suite the first time it ran the pseudo-class assertion added with the
  `:nth-of-type(n)` work.

- **`--css` implements `:nth-of-type(n)` / `:nth-child(n)`, the pseudo-class family
  its own captured paths are built out of.** The snapshot records
  `domCssSelector` as a full path of `:nth-of-type()` segments, and the matcher
  refused pseudo-classes — so the only selector the tool EMITS was one it accepted
  solely as a verbatim whole-string special case. Any edit (trimming the path,
  aiming at the 2nd sibling instead of the 1st) was rejected, which made driving a
  real form a `ui report` → read JSON → paste a ~400-char path → act loop for every
  interaction, and a pasted path silently pointed at a different node once the page
  re-rendered. Now `div.row:nth-of-type(2) input` resolves and drives input on both
  ports. The index is compared against the position the **page** reported — the DOM
  walk now carries `domNthOfType` / `domNthChild` per element — and never against a
  count of captured siblings: the walk drops `display:none` elements, so counting
  would answer `:nth-of-type(3)` with the third *visible* sibling, which is a
  silently-wrong tap rather than an approximation. Only a plain 1-based index is
  implemented; `:nth-of-type(2n+1)`, keyword arguments and every other pseudo-class
  are still refused by name (`':hover'`), and a positional query against a capture
  whose agent predates the new fields is refused as the version skew it is rather
  than answered as a miss. Pinned for both ports by seven new cases in
  `reticle-protocol/fixtures/selector-resolution.cases.json` (including a row whose
  page position is 3 while its captured position would be 2) and exercised on device
  in both e2e suites.
- **A flag a command does not read is reported, not dropped; and a selector miss
  names `--label`.** Two halves of the same measured loss. `act tap --package <pkg>
  --text "Tak"` answered `could not resolve selector '<empty>' to a point`, which
  reads as "your selector was empty" — the caller sees no connection to the flag
  they typed, and `--text` IS accepted by `act type` and `act wait`, so "unknown
  flag" was never the obvious reading. Every parsed `--flag` is now checked against
  what the command actually reads, and an unaccepted one is refused by name, with
  the commands that DO accept it: `unknown option --text for `act tap`. `--text` is
  accepted by: act type, act wait.` Validation runs before the backend is built, so
  nothing has touched the device when the answer comes back, and only the commands
  with a stated table (`status`, `app`, `ui *`, `act *`, `mutate`, `debug`) are
  validated — `rule` / `replay` / `trace` / `serve` are left alone, because a false
  "unknown option" rejects a call that used to work. Separately, the selector-miss
  message for an EMPTY selector listed `--test-id, --resource-id, --css, --ref,
  --point` and omitted `--label`, which is how a whole flow ended up driven by
  coordinates on screens whose only stable handle was the visible string (one dialog
  had `tvCancel` holding "Yes"). It now names `--label "<visible text>"` first, on
  both ports.
- **`ui <view> --package <pkg>` means the live tree.** `ui compact` and `ui coverage`
  (and every other render view) rejected `--package` on its own and demanded
  `--live --package`, so the first command of a session was reliably a failed one —
  measured repeatedly while driving a real flow. There was never an ambiguity to
  resolve: a package name is not a snapshot path, and `ui report`, `act *` and
  `status` all take `--package` directly. A path, when given, still wins, and
  `--live` still works for scripts that pass it. With neither, the error now names
  the form that works instead of the one that used to be mandatory.
- **A dead `--ref` says what a ref is, and names a handle that survives.** Refs are
  traversal indices, valid for the snapshot they came from: any relayout — in a
  WebView, any re-render — renumbers the tree. Measured on a hybrid screen, a ref
  read out of one `ui report` was frequently gone ~1s later, and the answer was
  twelve NATIVE refs (`r3`, `r6`, …), none of which can stand in for a DOM node,
  followed by a note about recycling lists while nothing had scrolled. The miss now
  states the lifetime, and on a screen carrying a DOM it offers `--css` handles that
  can actually be re-resolved (id, tag+class, or the tail of the captured path with
  its `:nth-of-type()` intact — never a bare `'input'` that matches the first of
  forty). The recycling-list note is suppressed for a ref miss on such a screen: it
  is a wrong lead there, not a weak one. Both ports, plus a documented statement in
  the skill that refs are single-snapshot handles.
- **A native field's prompt is projected, and a full field says why nothing landed.**
  The DOM side published `placeholder:"…"` while the native side published nothing,
  so an `EditText` reading `text="880 977 267"` was ambiguous — a prefilled value, or
  a hint showing through an empty field? Measured on a real form, a screenshot was
  the only way to tell, and a `type` into that same field (already at its
  `maxLength`) reported a bare `textLanded=none`, which reads as "the tool failed"
  rather than "the field is full" — two opposite next actions. Now an Android
  `EditText.hint` and a `UITextField.placeholder` project through the SAME
  `placeholder:` marker as a DOM `placeholder` (one `Node.placeholder()` accessor,
  since the caller's question is the same), which also makes them `--label` handles —
  for an empty field, often the only handle there is. Android additionally captures
  the field's `maxLength` from its own `LengthFilter`, and a loss explained by it is
  reported as `textLandedReason=at-maxLength(11)` instead of being retried over the
  clipboard, because re-sending cannot change a full field. iOS has no readable
  `maxLength` (limits live in a delegate), and that absence is stated rather than
  guessed at.
- **The DOM half of the tree has a focus channel, and a wrapper no longer reads as
  unreadable.** The platform focus sits on the host WebView while the caret is in a
  DOM input, so a web form's `type` could only ever report `focusLanded=ancestor`,
  and its read-back had nothing to follow. Measured on a real form: a selector that
  resolved a wrapper `<div>` instead of the `<input>` reported `textLanded=unreadable
  textReadback=unavailable:dom-node-is-not-a-text-input` while `ui compact` for the
  same region showed the value sitting in the field — a false negative that a
  screenshot was the only way to resolve, and one indistinguishable from a real
  failure. The DOM walk now reads `document.activeElement` (shadow-root aware), so
  the focused element is marked `focused` in the tree and a DOM field reports
  `self`/`descendant` like any other. The read-back follows it: a resolved wrapper
  reads back the input under it — the FOCUSED one when there are several, since the
  caret is not a guess — and when it still cannot read, the message names the node it
  inspected AND where the caret is (`dom-node-is-not-a-text-input (r407); the caret is
  in r408, which was not the node this read looked at`), instead of describing one
  node as though it were the other.
- **A DOM rect folded outside its own web view is reported.** A DOM rect is computed
  in page coordinates and folded into device coordinates through the host view's
  frame, the page's scroll offsets and any iframe offset; when that fold is wrong the
  failure is silent in the worst way — `act tap` aims at the reported rect, reports
  `settled=1`, and the touch lands elsewhere. Measured on one page of a real hybrid
  flow: rects offset by roughly 130px, a css tap missing twice, and only a screenshot
  showing it. Reticle now states the one case it can prove: a rect whose CENTRE falls
  outside the view that draws it is impossible for a correct fold, so a tap on such a
  node carries `warning: … folded to a point OUTSIDE the web view that draws it`,
  naming the host and a coordinate-free next step (`act activate --css`). Only the
  strong case fires — a partially-visible element legitimately hangs over its host's
  edge, and a smaller offset has no second source to be judged against, so guessing
  there would fire on ordinary screens. Both ports, with mirrored unit tests, plus an
  e2e guard that a correct fold stays quiet.

- **A tap says when something else gets the touch.** `act tap` resolved a selector,
  confirmed the rect had stopped moving, dispatched, and reported `settled=1` — and
  then the IME or a window above the target took the touch, which is byte-identical
  in the result to a tap that worked. Measured while driving a hybrid flow on a
  physical device: a button under the keyboard reported a clean tap and never
  submitted, and a small floating window belonging to an in-app debug overlay
  swallowed a form tap and opened its own screen. The fact was already computed on
  the READ side — `ui compact` prints `occluded-by:keyboard` on that same button and
  even names `act hide-keyboard` — so only the act path was silent. Every tap now
  carries an obstruction verdict, printed as a warning: `occluded:keyboard` (the IME
  covers this point — dismiss it first), `occluded:window` (a window above the
  target's takes it, naming the window), or `occluded:node` (an interactive node
  drawn over the target consumes it). A warning rather than a refusal, because a tap
  through a scrim is sometimes exactly what the caller means. A screen-sized
  interactive container is NOT an obstruction — an app that wraps its content in one
  full-screen clickable frame would otherwise warn on every tap, and a warning that
  always fires is one nobody reads; a real modal scrim is caught as a window
  instead. Pinned for both ports by a fifth case in
  `reticle-protocol/fixtures/screen-coverage.cases.json` (including the two quiet
  cases) and exercised end to end by the keyboard-trap and dialog/overlay sections
  of both e2e suites.
- **A tap aims at the part of the target it can reach, or refuses.** A node's frame
  is its LAYOUT box, and a tap at the centre of that box is only correct while the
  whole box is reachable. Two ways it stops being, both measured on a device and
  both reported `settled=1`: a sheet row with frame `y=2403 h=128` on a 2412px
  screen was dispatched at **y=2468, below the bottom of the display**, and a row
  scrolled UNDER a sheet's sticky header kept its full unclipped rect, so the touch
  went to the dimmed page behind the sheet. `act tap` now intersects the frame with
  every clipping ancestor — a native scroll container, a DOM element whose
  `overflow` is not `visible`, a dialog window — and with the screen. Nothing left:
  the tap is **refused**, naming the ancestor and `act scroll-to`, rather than
  dispatched at a coordinate no display has (refusing is right here because the
  tool computed the point, unlike a coordinate the caller typed, which is left
  alone). Something left: the tap aims at the visible part and prints a `note:`
  saying so, since the coordinate no longer matches the rect the tree reports. An
  ordinary layout parent is deliberately NOT treated as clipping — Android views
  draw outside their parents all the time, and a false clip would move taps that
  were landing correctly. Pinned for both ports by
  `reticle-protocol/fixtures/tap-reach.cases.json` and exercised by the LONG LIST
  section of both e2e suites.
- **The compact cap spends its budget on controls, not on whatever is first.**
  `ui compact` caps its item list and says so, but it took the first N in document
  order — which fails hardest on exactly the screens the cap exists for. Measured
  on a hybrid form: the page opened with a decorative digit-roller (a `<ul>` of 27
  hidden `<li>`s, each rendering as `9 8 7 6 5 4 3 2 1 0 …`, plus its wrappers) and
  those ate the whole budget, so the projection showed a screen full of odometer
  digits and NOT ONE of the form's inputs, labels or its submit button — all of
  them present in the same snapshot. "There are no controls here" is the worst
  thing a read command can say wrongly. The cap now fills by usefulness: controls
  first (interactive, or a role only a control has — so a disabled input and a
  JS-driven DOM checkbox still count), then nameable content (an id or a label),
  then scenery. Each rank keeps document order inside itself, so the survivors
  still read top to bottom; the selection changed, not the layout. On the real
  capture that prompted this, a 40-item cap keeps 36 interactive items where the
  old rule kept 8.
- **`type --clear` empties the field, or refuses to type.** The flag was accepted
  and did nothing at all — the worst shape a flag can have. Measured on a device:
  `type --clear --text "test1"` into a field already holding `test1` left
  `test1test1`, and into a field already at its `maxLength` it reported
  `textLanded=none` with no hint that the clear was the part that failed. Both read
  as a clean write to the caller. `--clear` now sends one Delete per character the
  field ACTUALLY holds (deleting what is there, not a fixed count, is the
  difference between clearing the field and eating the line above it), reads the
  field back, and reports `cleared=already-empty` / `cleared=emptied(6ch)` — or
  **refuses to type** when the field is still not empty, because appending under a
  result that looks like a replacement is the defect. Both ports: the iOS HID
  keyboard had no Delete in its ASCII table, so it gained one. Asserted end to end
  in the login section of both e2e suites.
- **A pass-through full-screen container stops poisoning coverage and occlusion.**
  Apps ship in-app debug overlays: an interactive `FrameLayout` the size of the
  display, drawing nothing but a small floating icon. Reticle treated it as cover.
  Measured on a login screen carrying one, both read commands went wrong in the
  same direction: `ui coverage` reported **1004 of 1462 touch-relevant cells
  unreachable — 31% addressable** while every control on the screen resolved and
  every tap landed, and `ui compact` stamped `occluded-by:<overlay>` on essentially
  every item, which makes the marker useless exactly where it matters. Two fixes,
  each keeping the case the rule was written for. Coverage still refuses to count a
  screen-sized container as cover, but those cells are no longer a **gap**: they
  get their own `container-only:` line and stay out of the addressable ratio, next
  to `inert` and `empty` (a boundary the container declares — a capped or
  unreadable DOM, a cross-origin frame — is answered earlier and still counts).
  Occlusion now asks whether the cover DRAWS at the point rather than how big it
  is: a second page pushed over a live one still occludes everything under it (a
  web view is opaque to touch wherever it lies, whatever its document holds), while
  a transparent frame only occludes where it has something of its own. Both e2e
  suites gained the false-positive assertions.

- **A coordinate tap now says why it had to be one, and the screen can be asked how
  much of it is unreachable.** `act tap --point` was the one degraded path that
  reported nothing: measured over a hybrid onboarding flow, 23 of ~50 taps were
  coordinates and no result said so, which is why the gaps that forced them could
  only be found by driving the flow by hand and counting. Every coordinate tap now
  carries a verdict, printed as a warning either way — `no semantic selector covers
  (x,y) — iframe:cross-origin: …` when the fallback was justified (with the boundary
  named), or `--point was not needed at (x,y): --test-id … resolves to rN` when it
  was not, which is the quieter loss: a coordinate throws away the re-resolution,
  the settle confirm and the stale-rect evidence a selector tap performs. A selector
  tap prints nothing, so the warning always means a coordinate was used. `ui
  coverage` is the whole-screen form: it samples on a stated grid and reports the
  addressable share plus every unreachable region by reason, host ref and rect.

  Three rules were corrected by a device rather than by reasoning. A **screen-sized
  tappable container** is not cover for the points inside it — an Android `WebView`
  is clickable and carries a resource id, so counting it reported a real hybrid
  screen as 100% addressable; its interior is `container-only` now. Only the **top
  window layer** at a point may answer for it — the home list behind a scenario
  screen has smaller nodes, so a smallest-node rule reached through the front screen
  and named `--test-id scenario.list` for a coordinate inside a cross-origin frame.
  And a **boundary host** is never cover: the cross-origin frame this came from was
  itself `tappable` with a test id, so every point in the third-party widget read
  "a selector covers this" while nothing inside it was readable. Captured-but-inert
  area is deliberately NOT counted as a gap, and the report says so: without pixels,
  a paragraph of text and a control the projection failed to mark are the same
  observation. Pinned by `reticle-protocol/fixtures/screen-coverage.cases.json`
  across both ports, and by a **COVERAGE** section in each e2e suite.

- **A cross-origin frame says why it is empty, and it is finally exercised.** The
  absence was already a documented boundary — `contentDocument` throws by browser
  policy and nothing in an app can override it — but it was a *silent* one, and an
  empty frame is byte-for-byte what a frame that has not finished loading looks
  like. A caller that cannot tell those apart retries, waits, and ends up measuring
  pixels: measured on a real third-party widget, four consecutive steps done by
  coordinate because nothing in the tree said to stop trying. The frame now carries
  `iframe:cross-origin`. `docs/boundaries.md` recorded this case as **not
  exercised** ("needs a second origin, and both suites run offline"); a `data:` URL
  gets an OPAQUE origin, so both twins — a pierced `srcdoc` frame and a genuinely
  cross-origin one — now sit on one screen with no network.

- **`--verify` says what it compared.** It printed `verify @x: no change` beside a
  trace recording 101 changes, because it watches only the node the selector names
  and the tap had replaced the whole screen. That reads as "the tap did nothing" —
  the opposite of what happened. It now says which node's fields were unchanged and
  points at `trace log` for the rest.

- **`--help` lists the commands.** It printed the one-line usage and nothing else,
  and a command with subcommands answered a missing one with `unknown app
  subcommand: <none>` — an error about what you did not type rather than a list of
  what you could. Both now name what exists.

- **A screen covered by another one, inside a single window, now says so.**
  Occlusion was window-level only: it scanned the windows above a node's own and
  stopped there. That misses the shape a hybrid app really has — a second screen
  pushed over a still-alive one *within* one window — and the miss is the
  silent-wrong-answer kind. Measured on a fixture of two web containers in one
  `FrameLayout`: the covered page's button projected as an ordinary `tappable`
  node, a tap on it reported `settled=1`, and nothing happened, because the touch
  went to the cover. `occludedBy` now also considers a later-drawn sibling whose
  rect covers the node's tap point — sibling order is draw order, so it is the
  same relation the window loop already used, one level down, and walking only the
  ancestor chain keeps it O(depth × siblings). The cover must be **interactive**,
  which is the honest limit rather than a shortcut: Android hands a touch to the
  topmost child that consumes it, so a decorative transparent frame does not
  occlude and is not reported as doing so. The fixture ships both variants, and
  the inset one is the false-positive guard: its genuinely visible controls carry
  no marker and still tap through.

- **A node clipped out of its container is not "visible".** An `overflow: hidden`
  roller or a scroll port lays its other items well outside itself, and
  `getComputedStyle` reports them as perfectly ordinary — `display` and
  `visibility` untouched — with rects that land inside the WINDOW viewport. Nothing
  told them apart from what is on screen. Measured on a real page, a 10-item
  animated counter put nine unseeable digits into the tree, where they padded every
  projection and got cited as `--label` ambiguities for a value the user could see
  exactly once. Such a node is now not visible, which is the treatment every other
  invisible node already gets: `ui compact` omits it, the semantic tree keeps it,
  and `custom.domClipped` names why. Deliberately conservative — a partially
  visible row stays visible, and a `position: fixed` box escapes an ancestor's
  overflow, as CSS says.

- **`ui outline` numbers what is on screen.** It numbered the whole scrollable
  content: measured on a real home screen, 135 aliases whose last entry sat at
  y=10800 on a 2412-tall device, with about 15 actually visible. The aliases exist
  to be tapped, and one that needs a scroll first was numbered as though it did
  not.

- **A DOM walk that runs out of budget says so.** The traversal caps itself at 300
  nodes and used to stop silently, so a partial DOM read as the whole page. It now
  marks its host `dom:capped(N)` with the count it did capture. The distinction
  from the projection's cap matters: nodes past the projection's are still in the
  snapshot and reachable with `ui tree` / `ui node --ref`, while nodes past this
  one were never captured at all. Found while writing the fixture for it: the
  budget check sat in the child loop's CONDITION, so it short-circuited before the
  walk was entered and the walk never learned it had run out — the flag would have
  shipped always-false.

- **`--css` matches a selector now; it used to compare strings.** Resolution was
  an equality test against each node's captured `domCssSelector` — the complete
  ancestor path the traversal script emits — so only a verbatim copy of that path
  could ever resolve. Both documented short forms missed on a real page:
  `--css '#pay'` unless `#pay` happened to BE the whole path, and
  `--css 'input.some-class'` on a page full of exactly such inputs. It is a
  structural match over the tree Reticle already has (tag, id, classes, parent
  chain): type, `#id`, `.class` and their compounds, with descendant, child (`>`)
  and pierce (`>>>`) combinators — `>>>` being an ordinary descendant relationship
  here, since pierced content is captured as children of its host. A full captured
  path still matches verbatim, so a selector copied out of a snapshot keeps
  working. Everything outside that grammar — attribute selectors, pseudo-classes
  (including the `:nth-of-type` that appears inside captured paths), `*`, sibling
  combinators, selector lists — is **refused by name** rather than answered as a
  miss: "not understood" and "no such element" lead to opposite next actions. The
  rule had also been written twice (the resolver's and the helper's `findNode`,
  each with its own comparison); there is one matcher now, pinned for both
  platforms by seven new cases in the shared selector fixture — which immediately
  earned its keep by catching the Swift side swallowing the refusal into a miss.

- **A `--css` miss stops dumping the page at you.** One miss printed twelve
  COMPLETE ancestor chains — about 6 KB — and the twelve were an animated
  counter's list items and a progress ring's `<circle>` elements: unranked, and
  unrelated to what was asked for. It buried the one line that said what happened.
  Candidates are now scored by how much of the query they actually carry (id
  outweighs class outweighs tag), printed as the shortest handle that names them
  rather than their lineage, and capped at six. A node sharing none of the query's
  tokens is dropped entirely — an empty list, with a line saying so, is a better
  answer than an arbitrary one.

- **A dropdown built out of divs is drivable without a screenshot.** The single
  largest source of coordinate taps measured on a real form: five select controls
  on one screen, each present before selection ONLY as a label — no `button`, no
  `select`, nothing marked `tappable` — so an agent read five labels and had no
  executable next step. A click handler bound in JS cannot be read from the page
  (`getEventListeners` is a devtools API), so a framework-built trigger publishes
  no handler to find; what it does publish is a widget `role`
  (`combobox`/`option`/`treeitem`/… — all of which were missing from the
  interactive set), `aria-haspopup`, `aria-expanded`, and — when nothing else is
  declared — `cursor: pointer`. All of them now make a node `tappable`. The cursor
  signal is the weakest and is treated as such: recorded as `custom.domCursor` so
  you can see when tappability rested on it, and applied only at the node where the
  pointer **starts**, because `cursor` is inherited and marking every descendant
  would turn one control into four (asserted both ways on the fixture). `expanded`
  joins `checked` as a first-class tri-state — a div-built select's options do not
  exist until it opens, so before the tap there is nothing to diff against and this
  is the only evidence a tap did anything — and ` popup:<kind>` says an empty
  subtree under a control is EXPECTED rather than a capture failure.

- **`--label` resolves a caption and the control it names to the control.** A form
  states a field's name in a separate element and points the control at it
  (`aria-labelledby`, `<label for>`), so one string legitimately belongs to two
  nodes in different subtrees — and only one of them does anything when tapped.
  The ambiguity refusal fired on exactly that pair, leaving a coordinate as the
  only way into the control `--label` exists to reach. The single *actionable*
  match now wins; two actionable matches is still a refusal, which is the case the
  rule is for.

- **A web form can be driven end to end without a single coordinate.** Three
  independent defects had to line up for that to be false, and all three were.
  `act type`'s read-back was refused for **every** DOM input
  (`dom-input-value-not-separable-from-placeholder`) — true while the bridge
  emitted `value || placeholder` as one string, and no longer true — which also
  meant the partial/none clipboard recovery, which only fires on a classified
  loss, could never fire for a web form at all. `--label` was missing from the
  list of selectors `type` **taps** before dispatching, so `act type --label
  "Postcode"` typed into whatever already held focus and reported success; that is
  the worst place for the omission, since a control with no id and no visible text
  of its own has `--label` as its only documented handle. And `--label` did not
  match a `placeholder`, which on a component-framework form is the only text an
  empty input has. Two smaller corrections fell out of measuring it: an empty
  input now reads as **empty** rather than unreadable (the agents omit a blank
  value, so there is no `text` at all — calling that "no text channel" turned the
  commonest state a field can be in into a missing check), and a DOM field is
  re-read up to 3× before its text is taken as final, because the characters go in
  through the IME and the page's own handlers run afterwards. Measured: a field
  that ended up holding `00-001` read back empty on the first attempt, which would
  have sent the recovery in to re-type text that had already landed. The e2e now
  fills the whole fixture through `--label` alone and asserts `textLanded=exact`
  with the field's own text on every step.

- **Two web fixtures for the arrangements every other one is blind to.** All
  existing web coverage renders 1:1 in a single full-bleed WebView — the one shape
  where a wrong page-to-device fold and a right one agree, so neither zoom nor
  container stacking was ever exercised. `scaled` renders at
  `setInitialScale(130)` with its target 300 CSS-px down the page; the new
  **Nested WebViews** scenario puts two live WebViews in one window with the
  overlay inset on both axes and its target 220 CSS-px into its own page. Both
  assert with a **coordinate** tap against the page's own `onclick` — DOM
  activation would fire the handler even if the reported geometry were nonsense.
  Both pass, which is the point: they were written to reproduce a suspected
  coordinate-fold defect and instead **falsified** it. `docs/blind-agent-gaps.md`
  records the cause being withdrawn while the original observation stays open — a
  gap is filed on what was measured, a cause is a separate claim and has to earn
  its own evidence.

- **A form screen no longer needs a screenshot to be read.** Measured driving a
  real multi-step onboarding flow: an `<input type="checkbox">` came back as
  `role: textField` with `domInputType: "checkbox"` sitting right beside it on the
  same node — the fact was captured and then discarded by the role mapping — and
  no node anywhere carried a toggle state, so the only way to tell whether a tap
  had ticked a consent box was to look at the picture. Four changes, one shape:
  an input's **type is its role** (`checkbox` / `radio` / `slider`, and `button`
  for `submit`/`button`/`reset`/`image`); `checked` is a first-class **tri-state**
  on `Node` where `null` means "not a checkable control" — kept distinct from
  `off` because "there is no checkbox" and "there is a checkbox and it is
  unticked" lead to opposite next actions — sourced from Android `Checkable`,
  Compose `ToggleableState`/`Selected`, DOM `checked`, and
  `aria-checked`/`aria-pressed` for a control a framework built out of divs;
  `placeholder` is **its own field** rather than a fallback folded into the value,
  which is what made an empty field and a filled one project identically (and
  what made `act type`'s read-back structurally unable to say whether text had
  landed); and `aria-invalid` + `aria-describedby` project as
  ` invalid:"<message>"`, so a validation error stops being a sibling node
  belonging to nothing. A DOM input also now carries its `name`, its
  `placeholder`, and an accessible name resolved the way a screen reader resolves
  it (`aria-label` → `aria-labelledby` → `title`/`alt`) — on a form built from
  framework components, with no `id` and no value on any input, those are the only
  handles that tell several identical fields apart. Pinned by `FormSemanticsTest`
  / `FormSemanticsTests` on both platforms and by a new **WEB FORM SEMANTICS**
  e2e section driving a `form` fixture that deliberately sets no id, no
  `data-testid` and no value anywhere — the complex fixture sets all three, so it
  could never reproduce the screen this came from.

- **`--label` could not resolve the controls it exists for.** It matched
  `text ?? contentDescription` — a fallback, not both — so any control carrying a
  value *and* an accessible label had the label shadowed by the value.
  `<input type="radio" value="b" aria-label="Plan B">` is the everyday shape of
  that, and `--label "Plan B"` could not resolve it: on a form fixture every
  aria-labelled checkbox and radio was unreachable through the one selector the
  skill documents for exactly these controls (they carry no id and no visible
  text of their own). Both names are matched now, exact-then-substring as before.

- **A disabled input was filtered out of the projection.** It fails every clause
  of `hasTargetingSignal` at once — not interactive, no id, no label, no value —
  so a form's not-yet-unlocked fields were simply absent from `ui compact`, which
  reads as "the app has no such field" rather than "not ready yet". Measured on an
  address form where the city and street fields unlock once a postcode is entered.
  A `placeholder` is now a targeting signal in its own right: it is both the
  evidence that the node IS a field and the only thing that says which one.

## 0.16.0 - 2026-08-03

- **Commands are scenarios now, not verbs.** `/reticle:tap` dispatched one gesture
  and `/reticle:inject` was a precondition — neither is a task anyone asks for, and
  both were restatement of skill content, which is exactly the drift the
  thin-wrapper rule exists to prevent. Both are **removed**. `/reticle:report`
  stays (a complete intent, and the entry point every flow starts from), and
  `/reticle:verify` is new: drive a flow end to end, then assert on the evidence
  Reticle captured, step by step. It absorbs both deletions — inject becomes step
  one's repair, a tap becomes one step of the batch — and makes the awkward
  readings mandatory rather than optional: an empty diff is two findings wearing
  one face, `window: UNFOCUSED` voids the step under it, `charGrid` is an
  approximation, and a boundary that blocked the check is not the app failing it.

- **The skill loads ~35% less to say the same thing.** `SKILL.md` was 941 lines /
  ~13.5k tokens, and all of it entered context on every trigger — including "what's
  on screen", for which the rule engine, the MITM CA setup, the session event bus,
  `act batch` and the trace formats are dead weight. It is now 573 lines / ~8.9k,
  and those ~400 lines live in `skills/reticle/references/*.md`, read on demand.
  What makes it work rather than just move text: the index is keyed on **when** to
  open a file, not on what it contains, and every seam where material left carries
  an inline pointer at the place in the flow where it would have been wanted.
  `validate_plugin.py` now guards the failure mode this introduces — a reference
  nothing points at is never loaded, a pointer at a missing file is a dangling
  instruction, and both are silent.

- **`--proxy-phone-onboard` was shipping and documented nowhere.** It prints a LAN
  provisioning URL, the CA's SHA-256 fingerprint and a QR
  (`~/.reticle/phone-onboard-qr.png`) so a real phone can scan-and-install the CA —
  while `docs/ios.md` steered the reader down the manual route (AirDrop a `.cer`,
  install, enable full trust). Now recorded with the three properties a caller needs
  first, read off Loom 0.0.12 rather than assumed: it rebinds the proxy to `0.0.0.0`
  itself (so `--proxy-bind` beside it is redundant), it fails with `no LAN IPv4
  address` when the Mac is on neither Wi-Fi nor Ethernet, and the provisioning
  server plus that LAN-wide bind stay up for the daemon's whole life. It provisions
  **trust, not routing** — the phone's Wi-Fi proxy is still the user's step. Both
  READMEs also stopped describing capture as if Android were the only target: iOS
  routing is deliberately never mutated, because the simulator would mean a
  host-wide proxy, a device rides its Wi-Fi setting, and a daemon dying mid-run
  would strand either on a closed port.

- **Nothing in a public repo may name something outside it.** A comment credited the
  injection route to a third-party app, and the device project pinned a
  `DEVELOPMENT_TEAM` that could only ever be the wrong one (every caller passes it
  on the command line). Both gone; the rule is in `AGENTS.md`, covering commit
  messages and PR descriptions too, since those are as public as the tree.

## 0.15.0 - 2026-08-03

- **Loom 0.0.5 → 0.0.12, and the three things that upgrade changed.** The bump
  itself is source-compatible (nothing in the engine API Reticle drives moved),
  but the newer engine can now be handed a HAR — and imported exchanges ride the
  same live flow stream as real captures, persist, and replay like any other.
  Unlabelled, someone else's capture would have landed in `events.jsonl` reading
  as evidence of what the app under test just did. `importedFrom` now names the
  file it came from, on the `network.*` payload and on every
  `GET /sessions/current/flows` summary; its absence is what makes a flow a live
  capture, and the new boundaries row says so.

  The same endpoint gains `headerContains` and `bodyContains`, which had been
  left out with a comment saying they existed only on Loom's main branch. Both
  are Loom's semantics verbatim rather than a Reticle-side reimplementation over
  a different corpus: `x-env: staging` must hit one header on both halves, and
  the body predicate matches what was *captured*, so a miss on a flow reporting
  `bodyCaptureTruncated` proves nothing about the wire.

  Third, `docs/boundaries.md` no longer calls Loom's flow-stream drops
  "genuinely silent" — 0.0.12 counts them per subscriber and logs them. They
  remain unreadable through any API, so the row stays; only its claim narrowed.

The five findings the 2026-08-01 audit left as low priority, closed. No new
capability; two of them change a reading, three are cost or clarity.

- **A `real` metadata value spells the same on both agents.** `displayString()`
  feeds `verify --custom` matching and trace diffs, and the two runtimes dressed
  their digits differently: Kotlin `1.0E17` / `Infinity` / `NaN` against Swift
  `1e+17` / `inf` / `nan`. An expectation written against an Android capture
  therefore missed the identical iOS one. The Java spelling is now canonical on
  both sides (it is a specified format; Swift's is not), pinned by twin tables in
  `MetadataRealFormatTest` / `MetadataRealFormatTests`. Residual and documented:
  for a few subnormals the runtimes still choose different digits.

- **The two `Endpoints` lists say where they deliberately differ.** Each called
  itself a mirror of the other while `/activate` existed only on iOS and
  `/editor-action` only on Android, with nothing saying so — a reader had to
  guess whether a missing endpoint was a platform fact or an unfinished port.
  Both are annotated with the affordance that justifies them, and the doc now
  states that anything else without a twin is drift.

- **The in-process iOS screenshot no longer holds N full-screen bitmaps.** It
  rendered every window into its own layer, kept them all, and composited at the
  end — on a large phone at 3x that is ~8 MB per attached window, peaking inside
  the app under observation. Windows are now folded into one bitmap as each is
  rendered, so the peak is the composite plus one layer. `ScreenshotCaptureTests`
  pins the compositing that moved into hand-written CoreGraphics: order,
  orientation, scale, and the skip of a window that refuses to render.

- **`screen.keyboard`'s pre-notification fallback stopped walking the tree.**
  Before the first keyboard notification arrives (agent injected into an app that
  has not focused a field yet), the monitor infers visibility from the first
  responder — and it found it by recursing through every view of every window, on
  every capture, forever, for an app that never focuses one. It asks UIKit's
  responder chain directly now.

- **`network rules import` writes once per file instead of 2N times.** An
  N-entry package looped through the single-entry upsert, taking the store lock,
  rewriting both index files and firing a full rule re-sync into the capture lane
  for every rule and every value. The package is validated up front, applied to
  copies, and persisted once — which also makes a rejected entry leave the index
  untouched rather than half-applied.

- **The real-device sample build works again, and a device screenshot says what
  it is.** The iOS sample has two build routes — SwiftPM for the simulator,
  xcodegen for a device — and only the SwiftPM manifest carried the `lottie-ios`
  dependency, so the device project had been failing at `Unable to find module
  dependency: 'Lottie'` since the Lottie scenarios landed (`Bundle.module`, which
  only SwiftPM synthesizes, would have failed right after). `e2e-ios.sh` never
  caught it because it only exercises the SwiftPM route. Both are fixed, and
  `e2e-ios-device.sh` now passes `-clonedSourcePackagesDirPath` at a copy of the
  simulator path's checkouts: Xcode keeps SPM state under its own DerivedData and
  does not share the `swift build` cache, so a fresh derived path re-mirrored
  `lottie-ios` (~176M, full history) from the network for bytes already on disk —
  measured at 14 minutes and still cloning, against a ~1 minute build reusing
  them.

  Validated end to end on an iPhone 13 Pro Max / iOS 26, which is what lets
  `docs/ios.md` and the skill state the boundary rather than imply it:
  `ui screenshot` on a **device** is the agent's in-process render with **no**
  fallback, because `simctl io` is simulator-only. Anything that is not this
  app's own window is absent from the PNG with nothing to switch to — the status
  bar (SpringBoard draws it), the keyboard's host window, another process's
  sheet. On the simulator a device-level capture still recovers those.

- **The skill's own description no longer hides iOS from itself.** The
  frontmatter still said "Inspect and drive a RUNNING **Android** app … when the
  task involves an Android app", while the body carried a full iOS section and
  every command took `--target ios`. That text is the gate for whether the skill
  loads at all, so an iOS request matched nothing and none of the iOS content
  below was reachable. It now names both platforms, SwiftUI accessibility beside
  Compose semantics, XCUITest beside Espresso/UiAutomator, the network-rule
  capability it had omitted, and the one asymmetry a caller plans around: a real
  iOS device is observation + in-process activation, not HID.

## 0.14.0 - 2026-08-01

An audit batch with no new capability in it: eighteen code changes, every one of
them a defect found by reading the code against the contracts it already claims
to hold, or a hot path measured and made cheaper, plus a documentation pass over
the same ground. Three classes dominate —
selectors that silently pointed at the wrong node or no node, projections and
waits that reported a partial reading as a complete one, and unbounded
waits/writes that could hang a helper, a host, or the app being observed.

- **Selectors stopped quietly missing.** `--label` scoped its match to "the
  highest window containing any visible node", and every window contains at least
  its own chrome — so the scope collapsed to "top window only" and any overlay
  (an iOS keyboard, a popup, a tooltip) blinded every label under it. The match
  now runs per window, top-down, and keeps the first window that actually
  MATCHES, falling back to all visible nodes. On iOS, `--point` hit-testing
  sorted refs lexicographically, which puts `r9` after `r10`: on any screen with
  ten or more nodes — every real screen — a point could resolve to a shallower
  view or one in a covered window. Both engines now share a numeric `RefOrder`.
  An empty `--region` entered the region path on Android (`''` substring-matches
  the first labelled region) while iOS ignored it, so one batch step tapped two
  different points; `''` is no region on both sides now. And the Swift region
  path resolved through `try? Render.labelMatch`, collapsing an ambiguous label
  into "no match" — turning `UNKNOWABLE` into `ABSENT`, the exact observer lie
  `WaitVerdict` exists to prevent; the ambiguity propagates now, like the Kotlin
  twin.

- **Projections declare their cap, and `act wait --idle` can see past it.**
  `compact` kept 200 items and `ui style` 500, dropping the rest with no marker —
  a capped projection read as the whole screen, against the repo's own rule that
  anything unreachable must name itself. Both now carry `truncatedItems` and end
  with `(N more … beyond this projection's cap — NOT listed here; still in the
  snapshot)`; the marker is in `docs/boundaries.md` and the skill. The same cap
  was worse inside the wait loop: the quiescence digest was built from the capped
  list, so on a screen with more than 200 signal-bearing nodes a change past the
  cap left the digest unchanged and `act wait --idle` reported a still-moving
  list as quiet. Both wait paths build the digest UNCAPPED, and the digest now
  folds in `isFocused` — a caret moving between two fields under a same-height
  keyboard changes no geometry, and a wait that calls that quiet hands back the
  wrong field.

- **A snapshot from a newer schema is refused instead of silently misread.**
  `schemaVersion` was written on every snapshot and read by no one. Both JSON
  configurations ignore unknown keys — they must, for additive changes — so a
  future producer's renamed field would decode into a default and the projection
  would present invented evidence as real. `requireSupportedSchema()` (Kotlin and
  Swift twins) now gates every snapshot ingested from outside the process: the
  helper's agent-HTTP fetch and `--snapshot` load, and the Swift host's render,
  fetch and trace paths. Only NEWER is refused — older still decodes with
  defaults by design — and the error names both versions and the direction to
  upgrade.

- **Three render drifts between the Kotlin and Swift halves.** Every render
  truncation clipped by UTF-16 units on Kotlin (`take`) and grapheme clusters on
  Swift (`prefix`): the two agreed on ASCII and disagreed on CJK and emoji, and
  Kotlin could emit an unpaired surrogate. Both clip by code point now, pinned by
  a 45-emoji fixture. `StyleObservation.fmt` rounded half UP on the JVM and half
  to EVEN in C's `printf`, so a 1px border at density 4 printed `0.3dp` on one
  side and `0.2dp` on the other. And `'1'` sat in the CSS initial-value list for
  opacity's sake while the check was value-based, so a page's explicit
  `z-index:1` — a stated stacking decision — was dropped as "the page said
  nothing".

- **A malformed snapshot bounds every tree walk instead of hanging it.** A
  snapshot can be loaded from disk or produced by a buggy agent, so a `parentRef`
  cycle, a children cycle, or one ref under two parents are legitimate inputs.
  `SemanticTree.build`, the label resolvers, `CompactObservation.from`,
  `StyleObservation.from` and `WaitPredicate`'s window walkers were unguarded on
  one or both platforms — `act wait` could hang forever, `ui report` could hang or
  overflow the stack, and a duplicated ref emitted a duplicated item.

- **A debugging request can no longer crash or wedge the app it observes.**
  Android's `runOnMainSync` documented that it swallows exceptions and did not:
  a screenshot OOM, an app `TextWatcher` throwing during a text mutation, or a
  clipboard write over the binder limit killed the host app's main thread. The
  in-app server had no write timeout (`soTimeout` bounds only reads), so a peer
  that connected and stopped reading blocked its worker inside `write()` once the
  buffer filled on a multi-megabyte screenshot; sixteen such peers exhausted the
  pool and `CallerRunsPolicy` then ran requests on the accept thread, so the
  server never accepted again until the app restarted. A watchdog now closes the
  connection at a hard 30s per-request deadline, and the 413 path drains the sent
  body so the diagnosis is not replaced by a connection reset. On iOS: window
  ordering is stable again (`sorted` is not, so two `.normal`-level windows could
  swap capture order between runs and flip occlusion and screenshot stacking),
  `runtimeInfo()` reads `boundPort` under the lock `start()` writes it under, and
  `start()` no longer holds the state lock across a blocking bind, which stalled
  every thread calling `Reticle.log()`.

- **Every remaining unbounded wait is bounded.** The JDWP reply read had no
  socket timeout — a target wedged behind a class-init lock hung the helper and
  the host waiting on it, with no cancel path (60s now, overridable, and the
  connection is terminal after). `HelperClient.shutdown()` waited forever, so
  Ctrl-C on `serve` hung until SIGKILL and idle-exit left a zombie daemon+helper
  pair; it escalates 2s → SIGTERM → 1s → SIGKILL now. `SocketHelperClient`
  treated a reply timeout as recoverable, leaving the late reply queued so every
  later call ran one answer behind, forever; a timed-out connection is dead now.
  The SSE stream buffered unbounded, so a half-open subscriber accumulated every
  event including network payloads (`.bufferingNewest(512)` now, mirroring the
  event ring). `awaitRuntime`'s budget was an attempt count that an unresponsive
  port stretched into minutes; it is a ~15s wall-clock deadline. And `Adb.run`
  returned the output buffer of a reader thread still alive after its bounded
  join — a clipped `pidof` reads as "app not running" — which now fails the
  result instead.

- **Numeric CLI options fail loudly.** `--proxy-port`, `--port`, `--event-limit`,
  `--proxy-max-request-body-mb`, `--depth`, `--settle-timeout`, `--trace-delay`,
  `--verify-timeout`, `--type-delay`, `--timeout` and `--quiet-for` silently
  substituted their default on an unparseable value — a typo'd `ui render
  --depth` printed an EMPTY tree. They now throw naming the flag and the value.

- **Helper state stops leaking onto the device.** `ForwardRegistry.cleanup()` ran
  only after a clean stdin EOF, so a SIGTERM from the host leaked every forward of
  the session onto the resident adb server (shutdown hook now, idempotent). The
  ANR guard's `--restart-under-debugger` relaunch ran before the restoring
  `finally`, so a refused relaunch left the persistent debug-app marking behind
  and the target kept getting force-stopped on later runs. And when the developer
  had ALREADY marked the target as the debug app themselves, `restore()` ran `am
  clear-debug-app` and destroyed their marking — that case is a no-op now.

- **Host-side races.** The daemon's helper-broker route ran the synchronous,
  lock-serialized `helper.call` (up to 60s) on the Swift cooperative pool, so
  concurrent `--use-daemon` requests against a wedged helper could occupy the
  whole pool and freeze every other route; it blocks on a dedicated serial queue
  now. The daemon's cold-start probe→unlink→bind→listen could interleave so a
  losing daemon unlinked the winner's freshly bound socket; the sequence is
  serialized under an `flock`'d lock file. The rule and flow daemon clients wait
  `timeout+1` so URLSession's specific error beats a generic "timed out", and the
  flow client's budget sits above the lane's worst path.

- **Capture and wait hot paths got measurably cheaper.** `collapseWrappers` ran a
  parent-chain walk per (anonymous, named) pair — O(unnamed × named × depth) with
  two allocations each, inside every `CompactObservation.from`, which the wait
  loop polls every 100-250ms; ancestor sets are memoized per ref now, and anchor
  order (so, which survivor inherits `isInteractive`) is unchanged. The Android
  agent caches reflective method lookups — the Compose char-grid loop cloned the
  whole `Method` array per character offset — and fetches `GetTextLayoutResult`
  once per text node instead of twice. iOS builds one `TextLayoutStack` per
  `RegionProbe.probe()` instead of up to three per text view, each of which
  rebuilt a full `NSTextStorage`/`NSLayoutManager` and re-ran layout on the host
  app's main thread. The helper consults `ForwardRegistry` before forking `adb
  forward` (one `act type` paid that 30-80ms fork 6-8 times), and self-heals a
  stale entry. `EventStore` streams reads in chunks instead of loading whole
  `events.jsonl` files per request — and the CURRENT session's history now reads
  from disk like a historical one, so events older than the in-memory ring stop
  disappearing from the panel.

- **One new boundary recorded.** Reading `UITextView.layoutManager` — the
  fallback layout stack a region probe needs — irreversibly downgrades that view
  to TextKit 1 compatibility mode on iOS 16+. The evidence and the side effect are
  the same act; there is no read-only probe, so `docs/boundaries.md` states it: a
  snapshot is not free on TextKit-2 screens, and a layout shift after observation
  must not be attributed to the app.

- **The docs were audited against the code that shipped above.** Seven claims no
  longer held — `--label`'s window scope, the command surface, the count of Swift
  library targets, an `awaitRuntime` item already done, `whistle` where the engine
  is Loom, a `ui subtree` that does not exist, four missing endpoints, and a map
  node that put selector resolution in the helper. Three behaviors shipped with no
  documentation at all and now have some: the projection truncation marker, the
  `schemaVersion` refusal, and this release's own entry. Redundancy that had begun
  to drift apart was given one owner — the launcher resolution order (four copies),
  `act batch` in the skill (explained twice, the second copy filed under the
  keyboard section), the mutation allowlist (stale where it was duplicated), and
  the document map itself, which `AGENTS.md` now owns. `DESIGN.md` claimed a 1:1
  correspondence with the panel's CSS tokens that was never implemented; it is
  labelled a target spec now rather than described as current. `README.zh-CN.md`
  had drifted past abridgement into missing capabilities and is back at parity.

- **Docs-only changes no longer wait on the macOS build.** A `scope` job classifies
  the diff and the ~14-minute Swift host + native-image job is skipped when nothing
  outside `docs/`, `skills/`, `commands/`, top-level `*.md` and `LICENSE` changed.
  The checks that actually verify documentation — architecture-map sync, translated
  heading skeletons, manifest and version lockstep — run on every change, docs
  included. The classifier fails open: an unknown diff range runs the full build.


## 0.13.0 - 2026-07-29

A hardening release: the two in-process agents went from zero automated coverage
to 100 unit tests between them (69 iOS, 31 Android), every projection an agent reads is now rendered
from the protocol module rather than once per host, and three things that were
true only by convention (the Swift half of the shared fixtures running at all,
"one place spells the helper's method names", the architecture map's two copies
agreeing) are enforced by CI.

Two real defects fell out of writing the tests rather than out of a bug report —
an iOS wrapped-label geometry bug that put a second-line link's rect outside the
label, and an iOS agent that did not compile under CI's Swift 6.1 at all — plus
one boundary hole (the daemon's helper broker forwarding any method string) and
one leak by construction (probes with no way to retract them).

- **Docs caught up with what the code does.** Three claims had gone stale: the
  skill's Rules section still said an empty action diff is evidence the tap hit
  nothing (0.12.0 made it two readings, and the skill's own body already said so —
  the rule contradicted the page it was on); the roadmap's feature table listed
  `@N` aliases as a plain Drive capability when the outline cache is Android-only
  and `Render.swift` says as much in place; and the sample `trace log` output
  predated the current wording. The app-authored channel (`log` /
  `attachMetadata` / `registerProbe`, and now the retract) is documented in the
  README for the first time — it existed only in a changelog entry from months
  ago.

- **The bilingual roadmap is checked for structural drift.** `docs/roadmap.md`
  and `docs/roadmap.zh-CN.md` are one document in two languages, and the roadmap
  is where scope decisions are recorded — a section added to one and not the other
  gives two readers two different answers to "is this in scope". Prose cannot be
  diffed across languages, but the skeleton can:
  `scripts/validate_translations.py` compares the heading-level sequence and the
  ordinals of the numbered sections, which is exactly what changes when a section
  is added, removed or reordered. `README.zh-CN.md` is deliberately excluded and
  said to be so in the script — it is an abridged translation by choice, and an
  unchecked pair should be unchecked on purpose rather than by omission.

- **The architecture map's two copies can no longer drift apart.** The map ships
  twice by design — `map.json` for agents, a verbatim copy embedded in
  `index.html` for the interactive page — and the README told a contributor to
  resync them by hand, which is to say sometimes. Measured: the embedded copy was
  missing an entire flow step and still claimed version 0.11.0 while the repo was
  on 0.12.0, so a person reading the page and an agent reading the JSON were being
  told different things about the same system.

  `scripts/validate_architecture_map.py` is now a CI gate. It asserts the two
  copies agree, that `meta.version` matches the repo-root `VERSION`, that every
  edge endpoint and every id a flow step cites resolves to a real node or edge (a
  typo'd id renders as a step that highlights nothing), and that every fixture and
  module path the map names exists. `--fix` rewrites the embedded copy from the
  JSON, so maintenance is one edit plus one command.

- **The daemon's helper broker no longer forwards any string a caller sends.**
  `POST /helper/rpc` (opt-in, `serve --helper-broker`) took a `method` straight
  off the request and handed it to the helper process — the one path in the host
  where a stringly-typed call bypassed the typed `HostBackend` surface everything
  else goes through. Localhost-only, so this is a boundary fix rather than a
  vulnerability, but a boundary with a hole in it is not the boundary
  `docs/architecture.md` describes. The broker now refuses an undefined method
  with a 400 naming it, before the helper sees it.

  The gate is a new `HelperMethod` enum, which `AndroidBackend` also spells its
  calls through — so "the one place the method names are written down" is
  compiler-enforced now rather than conventional, and a typo in a literal can no
  longer compile and fail later on a device. `HelperMethodContractTests` parses
  the method table out of `reticle-protocol/helper-rpc.md` and asserts the enum is
  that same set, so adding a method to the protocol without a case (or inventing a
  case the protocol does not define) fails the build.

- **The view walk is under test on both platforms, and probes can be retracted.**
  `SnapshotCapture` — what every command ultimately reads — was the largest piece
  of either agent with no coverage, because a unit-test process has no attached
  window (Android) and no `UIWindowScene` (iOS) to walk. Both captures now take
  their window roots as an argument, defaulting to the live enumeration
  production uses, and that one seam makes the whole walk testable over a
  hand-built hierarchy: the application root and its one node per window, every
  node reachable from the root with agreeing parent links, tags /
  accessibility identifiers becoming `testId`, frames in screen coordinates, an
  invisible node kept in the snapshot but filtered out of `compact`, two captures
  of one tree agreeing on every ref (which is what makes `mutate --ref` land on
  the view the caller read), a ref resolving back to its live view, and the
  semantic projection staying connected.

  Writing the probe case surfaced a gap worth fixing rather than working around:
  the probe registries were process-global with no way to remove anything, so an
  app that published a screen's probes on entry could not retract them on exit and
  a stale `testId` stayed addressable on every later screen.
  `ReticleProbeRegistry.clear()` (Android) and `Reticle.clearProbes()` (iOS) close
  that, and the tests use them to stop leaking state into each other.

- **The Android agent has unit tests too, against real framework objects.** The
  AAR had a `src/main` and nothing else: `RegionProbe` — 615 lines deciding where
  a tap inside an agreement row actually lands — was covered only by the device
  e2e. It now has a Robolectric suite driving a REAL `TextView` holding a REAL
  `Spanned`, laid out by the real `android.text.Layout` every rect is derived
  from, plus the mutation allowlist. `:reticle-agent:android:testDebugUnitTest`
  runs in CI and at release.

  One setup detail is load-bearing and is written down in
  `src/test/resources/robolectric.properties`: Robolectric's DEFAULT graphics
  mode fakes text metrics — every glyph one unit wide, `getPrimaryHorizontal`
  returning nonsense, nothing ever wrapping. A suite written against that would
  assert the fake and pass while the probe produced garbage on a device
  (measured: the same string lays out as 1 line under the default and 3 under
  `graphicsMode=NATIVE`). The tests therefore run in NATIVE graphics mode, which
  is also why they pin an SDK level newer than the agent's `minSdk`.

- **The in-process iOS agent has unit tests.** It carried the whole iOS capture
  surface with no automated coverage at all: the only thing that ever exercised
  `RegionProbe`, `TextLayoutStack`, `SwiftUITextRegions` or `LottieBridge` was a
  device e2e run, on a Mac, by hand. `reticle-agent/ios` now has a
  `ReticleKitTests` target — 58 tests over the text geometry, the four region
  channels, the Lottie composition reflection, the mutation allowlist and the
  HTTP framing — run by `scripts/test-ios-agent.sh` (XCTest on a simulator, which
  is the only runner that can hand UIKit code real views, a real window and a real
  TextKit stack) and gated in CI and at release. What they deliberately do not
  cover is the whole-screen walk, which needs a real scene and stays the device
  suite's job; that boundary is stated rather than papered over.

  **They immediately found a real bug in wrapped-text geometry.** `UILabel`
  exposes no layout API, so the probe rebuilds an equivalent TextKit stack — and
  `UILabel.attributedText` carries an `NSParagraphStyle` whose `lineBreakMode` is
  the label's default `.byTruncatingTail`, which OVERRIDES the text container. An
  ordinary multi-line label (`numberOfLines = 0`, default break mode — an
  agreement row, in other words) therefore laid out as one endless line: its char
  grid claimed a single line running far off the right edge, and a link on the
  second visual line resolved to a rect outside the label entirely. Both the
  container's mode and the string's own paragraph styles are now corrected to
  `.byWordWrapping` for a multi-line label, and the layout width is clamped to the
  label's bounds. A wrapped agreement row was already the case
  `docs/architecture.md` calls out for Android's `rectsForRange`; iOS had the same
  trap through a different mechanism.

- **The Swift half of the protocol twins now runs in CI.** Every derivation in
  `reticle-protocol` exists twice — Kotlin in `reticle-core`, Swift in
  `reticle-swift` — and the shared fixtures under `reticle-protocol/fixtures/`
  are the only thing stopping the two from slowly answering differently. The
  Kotlin half was gated by `:reticle-core:test` / `:reticle-helper:test`; the
  Swift half was gated by nothing. `reticle-swift` is a path dependency of the
  host, so CI compiled `ReticleProtocol` on every push and never executed one of
  its 25 assertions — `SelectorResolutionContractTests`,
  `WaitClassificationTests`, `StyleObservationTests` and the
  `CompactObservation`/`SemanticTree` mirrors of `reticle-core`'s own tests all
  passed by never being asked. `swift test --package-path reticle-swift` is now a
  step in both the CI and release workflows, so a one-sided fixture change fails
  the build that made it rather than a device run three commits later.

- **CI now compiles the in-process iOS agent.** `reticle-agent/ios` holds the
  whole iOS capture surface — the UIKit walk, the accessibility-derived SwiftUI
  bridge, region probing, the WKWebView DOM bridge — and is UIKit-only, so
  `swift build` on the host triple never sees it. It was therefore the one
  shipped component with no build gate whatsoever: a break surfaced only on a Mac
  with a simulator attached, which in practice meant during an e2e run. The
  macOS job (and the release gates) now run `scripts/build-ios-agent.sh`, the
  same iOS-Simulator-SDK build `scripts/e2e-ios.sh` relies on. This is a compile
  gate, not a test gate — the agent still has no unit tests, and that gap is
  named here rather than implied.

- **The text an agent reads is now rendered from the protocol module on both
  platforms, and pinned by one fixture.** `compact`, `tree`, `tree --semantics`
  and `regions` were formatted twice: `HelperRenderCommands` in the Kotlin helper
  for Android, `Render` in `ReticleProtocol` for iOS. The *derivations* were shared
  and fixture-pinned; the *formatting* was not, so the two could agree on every
  field and still print one screen two ways — which is exactly how `compact`
  drifted before. `StyleObservation` had already solved this by owning its
  `render()`; the same move now covers the rest. `dev.reticle.core.Render` is the
  Kotlin twin of `ReticleProtocol.Render`, the helper calls it, and
  `reticle-protocol/fixtures/snapshot-render.cases.json` drives both suites — six
  cases covering window grouping, the keyboard and lost-focus headers, the fold
  footer, every boundary marker (`dom:unavailable`,
  `dom:unsupported-kernel`, `pixels:unavailable`, `screencap:blank`, both wheel
  shapes, `scroll:`), and an iOS snapshot with regions and a char grid.

  One real divergence fell out of writing it: `SemanticTree.build` inserted kept
  nodes in `HashSet` order on the Kotlin side, and that order decided the
  synthesized root's child list — so a tree with several top-level kept nodes
  printed in an arbitrary order the Swift twin (which walks the tree) did not
  share. Both now build in document order, via a new
  `Snapshot.refsInDocumentOrder()` that says why in one place: a map's order is a
  decoding detail, and a `Dictionary`'s is hash-seeded per process on the Swift
  side. `regions` was ordered by map iteration for the same reason and is now
  document-ordered too.

  What stays host-side is what genuinely is: loading or fetching the snapshot,
  window scoping, `ui node` (it renders through selector diagnostics only the
  helper has), and the Android-only `@N` alias cache — the one projection with no
  Swift twin, which `Render.swift` already names as unported.

- **The DOM traversal script is one file now, not two hand-copied strings.** Both
  WebView bridges run the same JavaScript, and it lived as a 174-line string
  literal in the Android agent and again in the iOS agent, kept in step by a
  `KEEP IN SYNC` comment and nothing else. Worse, Kotlin raw strings and Swift
  multiline literals escape differently (`\s` vs `\\s`), so the two copies could
  not even be compared with a diff — a reviewer had no mechanical way to tell
  whether they still agreed. (They did, as it turns out; the extraction was a pure
  refactor.) The traversal now lives in
  `reticle-protocol/scripts/dom-traversal.js` and is embedded in
  `dev.reticle.core.WebViewDomScript` and `ReticleProtocol.WebViewDomScript`, each
  asserted equal to that file by its own suite — so editing one embedding, or the
  file, fails a build rather than giving the two platforms different DOM readings.

  Embedded rather than loaded from a resource on purpose: the Android agent also
  ships as a payload dex that `app inject` pushes into a live process, and a dex
  carries no resources — a resource read would work in the linked build and fail
  exactly on the unlinked path. Both suites also assert the script still contains
  no mutating call (`.click(`, `.innerHTML =`, …), since "read-only" is the claim
  the whole bridge rests on.

- **Selector resolution now lives in the protocol module on both sides.** The
  action path's resolution table is pinned across languages by
  `reticle-protocol/fixtures/selector-resolution.cases.json`, and the Swift half
  (`SelectorResolution`) sits in `ReticleProtocol` — while the Kotlin half
  (`SelectorResolver`) sat in `reticle-helper`, a layer *above* the module that
  fixture describes. That asymmetry cost more than tidiness: the two halves of one
  contract lived at different layers, so nothing told the next contributor where a
  new resolution rule belonged. `SelectorResolver` and its two tests move to
  `reticle-core`; `Node.domCssSelector()` moves with them (resolution reads it, and
  the Swift twin has always been on the model).

  The refusals move too. `AmbiguousLabelException` and `RegionMissException` are
  `reticle-core` types rather than `CliError` subclasses — which costs nothing,
  since the helper's RPC layer reports any throwable by message, and keeps a
  refusal travelling with the rule that raises it. They stay two distinct types for
  the reason they always were: a poll loop must tell them apart, because an
  ambiguity makes an answer `unknowable` while a phrase not yet on screen is an
  honest negative a `wait` should keep waiting on.

## 0.12.0 - 2026-07-28

- **An action answered by a toast no longer reads as an action that missed.** A
  submit whose backend rejected it came back `0 change(s)`: the screen was
  byte-identical before and after, and the docs read that as evidence the tap hit
  nothing — so the reporter went looking for a targeting problem that did not
  exist. The tap had landed; the app answered with a `Toast`, and on Android 11+
  that toast is drawn by the SYSTEM in a window of its own. Four channels measured
  at once on an API 36 emulator while one was on screen: view tree — absent;
  in-process screenshot — absent; `adb exec-out screencap` — present;
  `dumpsys notification`'s Toast Queue — **the text verbatim**.

  Every `act` now watches that queue and reports `toast=` / `toastKind=` /
  `toastDuration=` (`toastCount=` for more than one). Host-side over `adb shell`,
  so it needs no agent and touches no hidden API. `trace log` leads the step with
  `! transient message shown: "…"`, and — the other half — the empty-diff line
  stops asserting a miss: with a toast recovered it reads `(no other observable
  change …)`, and without one it now names both readings instead of the first.
  `--no-toast-probe` turns the watch off.

  The three things called "a toast" are three different problems and are kept
  apart, because blurring them would replace one wrong claim with another.
  Measured: `Toast.setView` and a `WindowManager` overlay belong to the app's own
  process and are **already** nodes carrying their text — only the system-drawn
  text toast was ever invisible. A custom-view toast's queue record holds a
  callback and no string, so `toastKind=custom-view` says the text is a node
  instead of quoting an empty message; an overlay never enters the queue and is
  reported as no toast at all. A toast from ANOTHER process is filtered out by
  package rather than attributed to the app under test.

  The sampling detail that decides whether this works: samples ride along with
  work the action was already doing, but the one that matters is taken at the END.
  Resolving a selector and confirming its rect settled can eat ~250ms before the
  touch is even synthesized — the first cut sampled the whole front of its
  schedule before the tap landed and found nothing every time. `scenario.toasts`
  is the fixture; the Android e2e drives all three kinds and the `trace log`
  rendering.

- **`act type` reports what LANDED, not what it sent.** `chars=N` only ever counted
  characters dispatched. Measured on a physical device: `--text "10000"` returned
  `chars=5`, exit code 0, focus correct — and the field held `100`, while the field
  beside it took the same five characters intact. The difference is what each field
  does per keystroke: the lossy one reformats in a `TextWatcher` and re-renders a
  widget bound to it (101 changes in the trace against the other's 6), and
  `adb shell input text` delivers the string as a burst of key events that a
  re-layout in the middle of can eat. The damage surfaced several steps later as a
  validation failure against a value nobody typed.

  So `type` now reads the field back: `textLanded=exact|reformatted|partial|none|
  changed|unreadable`, the field's actual `text=`, and `landedChars=` for a partial.
  The split between `partial` (a proper prefix — the burst-loss shape) and `changed`
  (uppercasing, masking, a `maxLength` rewrite) is deliberate: an app transforming
  its own input is not a defect and Reticle does not call it one. `reformatted`
  (`10000` -> `10,000`) is likewise everything you sent, dressed.

  Only `partial` and `none` are repaired, once, by re-sending over the clipboard —
  which a `TextWatcher` sees as a single change rather than a run of keystrokes —
  and only when the field was EMPTY beforehand, since `type` inserts at the caret
  and there is no way to undo a partial insertion into existing content without
  guessing what the caller meant to keep. It never repairs silently: `recovery=`
  says what the key path did before the clipboard re-send. `--type-delay <ms>` is
  the caller's own escape hatch (one `input text` per character, at that pace) for a
  field known to lose the burst. A field with no readable value says
  `textLanded=unreadable` with a reason (`runtime-unreachable`,
  `dom-input-value-not-separable-from-placeholder`, ...) — never a claim it landed.
  `scenario.reformattingField` is the fixture; the Android e2e drives all three
  paths.

- **A Compose text field's value is on the wire.** Found while closing the above: a
  Compose field keeps what the user typed in `SemanticsProperties.EditableText`,
  apart from `Text` (which on a Material `TextField` is the LABEL). The bridge read
  only `Text`, so `ui compact` showed `#compose.codeField composable` — a text field
  with nothing in it — and `type` had no channel to check that six characters had
  arrived. Now the value comes through as `custom.editableText`, a node that has one
  reports `role=textField`, and a `BasicTextField` (no label) carries it as the
  node's text: `#compose.codeField textField "246813"`.

- **`docs/boundaries.md` corrected on secure fields.** The row on typed passwords
  claimed "a snapshot never contains a secure field's contents". It never did:
  `TextView.getText()` returns the raw text of a password field (masking is a
  display transformation), so the snapshot carries it, and the read-back above now
  prints it as `text=` too. Measured on an API 36 emulator with a
  `TYPE_TEXT_VARIATION_PASSWORD` field: `#login.codeField textField "hunter2"`.

- **`ui compact` folds anonymous layers into the node they wrap.** UI toolkits build one
  on-screen row out of several views and only one of them is nameable: measured on an
  iOS simulator, a `UIPickerView` row is three compact lines — the cell, the label, and
  the cell's content view — of which two are anonymous rectangles at the same place. A
  two-column wheel came to 86 lines, 46 of them carrying nothing an agent could act on,
  and a caller reading that could not tell which of three lines was the row. Now 42.
  Across every e2e artifact the iOS suite produces the fold removes 23% of compact
  lines; on the wheel screen it is 52%, on a list screen ~45%. Android is essentially
  unaffected (0.2% — 2 lines across 32 snapshots, both an `AndroidComposeView` host),
  which is the expected asymmetry: its view trees are not built this way.

  The rule is deliberately narrow, because a projection that drops the wrong thing is
  worse than a verbose one. A layer folds only when **all** of these hold: it has no
  identity of its own (no id, label, text, region, char grid, `scroll:`, `wheel:`, css
  selector — the only reason it was kept is `isInteractive`); a NAMED node's tap point
  falls inside it; it **hugs** that node (at least as large, at most 2× its area, so a
  page-sized container that merely contains a label is not a wrapper of it); the two are
  related (ancestor, descendant or siblings, so unrelated overlaps never merge); and it
  is neither a window/application node nor the focused one — window nodes are structure
  named by the window header, and "this node holds focus" is a precise claim that must
  not migrate. The survivor **inherits `tappable`**, or a folded row would read inert and
  be skipped. Nothing leaves the snapshot: every folded node keeps its ref, frame and
  properties, reachable with `ui node --ref` and visible in `ui tree` — and when anything
  folded, `compact` says how many, so the token-cheap view never quietly claims to be the
  whole picture.

- **`--label` no longer refuses a row just because the platform draws it three times.**
  Follow-up to the wheel work, found by reading the iOS wheel scenario's real capture:
  `UIPickerView` renders its magnifier bands as SEPARATE table views, so the row under
  the selection exists 2-3× at one spot. Measured on a simulator: `'09' at 50,487 /
  50,487 / 42,487`, and `act tap --label "09"` came back *"matched 3 visible nodes …
  Refusing to guess"* — on the wheel `docs/boundaries.md` said a label tap selects, and
  for precisely the values worth tapping (the selection and its neighbours; a distant
  row like `13` has only one band and worked fine). The three candidates were the same
  on-screen row, so the refusal protected nothing. Matches stacked on ONE rect — every
  candidate's tap point inside every other's rect — are now collapsed to one target and
  reported as `source=label:coincident`, so the layering is stated rather than hidden.
  Genuine ambiguity is untouched: `--label "15"` on the same screen still refuses,
  because 15 is an hour AND a minute, two different places. Both resolvers change
  together and the shared `selector-resolution.cases.json` pins the new rule, so Android
  and iOS cannot drift on it.

- **A wheel column no longer reads as a decorative empty view.** A wheel paints its
  candidate values onto its own canvas, so an Android `NumberPicker` publishes only its
  selection and a third-party self-drawn wheel (`WheelView` / `LoopView` / `PickerView`
  — what most date and region pickers actually use) publishes nothing at all: no items,
  no selected value, no `scroll:` travel, no regions. Three rectangles. That silence is
  the bug — it is indistinguishable from an empty view, so a caller has no cue to switch
  tactics and ends up reverse-engineering the row pitch from screenshots: four
  screenshot round-trips and a hand-derived pixel constant for what is semantically
  "select 1995". Nodes now carry `suspectedWheel` (a hint from the widget FAMILY, like
  `suspectedMultiRegion` — the only thing knowable from outside a canvas), and `ui
  compact` renders it as `wheel:opaque` or `wheel:selection-only`. The two are kept
  apart deliberately: collapsing them would understate what a `NumberPicker` offers and
  overstate what a self-drawn wheel does. `DatePicker`/`TimePicker` are deliberately NOT
  matched — in calendar/clock mode they materialise real tappable nodes, and marking
  those "unreachable" would be a wrong claim in the other direction — and neither are
  text views: a `NumberPicker`'s value field is `NumberPicker$CustomEditText`, so a name
  match alone marked the one node whose value IS readable as `wheel:opaque`, right under
  its parent's honest `wheel:selection-only` (caught on an emulator, now asserted). The sample's
  wheel-picker scenario gains a genuinely self-drawn third column so the `opaque` case
  has a fixture, and the skill now states the recipe the marker implies (swipe along the
  column, verify against the app's own committed state, never `type`).

  **Not shipped, and why:** an `act pick --value 1995` primitive. It cannot verify what
  it did — for an opaque wheel there is no value to read back, and `scroll-to`'s
  contract is precisely that it converges on a selector that resolves. A "pick" that
  dispatches swipes and reports success without evidence is the exact failure shape this
  project exists to avoid, so the marker plus the documented recipe is what is honest
  today.
- **Stacked screens read as two screens now, not one shuffled list.** A capture holds
  every live window of the process, and on Android a form pushed over a still-alive
  host page is the common case rather than the exception. `ui compact` and `ui outline`
  flattened both windows into one geometry-sorted list, so they interleaved: the two
  `#action_bar_root` / `#content` roots appeared twice, `#etContent` four times, and the
  form's own fields sat 12 aliases apart with unrelated content wedged between them —
  on the reported screen the relevant nodes were about a third of a 99-line outline.
  The information was technically present as a per-node `occluded-by:rN` suffix, but
  that marker is overloaded (it also means "under the keyboard" and "under a popup in
  the SAME window") and recovering "just the top window" meant filtering text by an
  occluder ref you had to identify first. Now: `CompactItem` carries `windowRef`; with
  more than one window in the capture both views group their lines under a `window
  <ref> <what> [top]` / `[behind the top window]` header, topmost first, dropping
  nothing; and **`--window top`** (or `--window <ref>`) on any `ui` view narrows the
  capture before rendering. The narrowing is done to the SNAPSHOT
  (`Snapshot.scopedToWindow`), so `tree`, `compact`, `outline`, `style` and the `@N`
  alias numbering all scope together and no renderer has to learn about windows. Outline
  numbering also now starts in the top window, so `@1` is a node you might actually act
  on. A single-window screen is byte-identical to before — and so is every ITEM line on a
  stacked one: the headers are new lines a consumer can skip, but the items are not
  indented, because a stacked screen is the common case and shifting them would break
  every `grep '^#selector'` written against this output most of the time rather than
  rarely.
- **`act type` verifies focus, not just dispatch.** Its contract is "give it a selector
  and the text lands in THAT field", and the only thing making that true was a tap on
  the resolved rect. That is not enough for the commonest app-owned compound widget: an
  outer container carries the stable, unique test id and the real `EditText` is nested
  inside it with a generic id repeated down the page, so the container is the only
  handle a selector can name — and tapping it moves no focus. Measured on a physical
  device: `chars=4 focusedVia=semantic:testId`, exit code 0, and the field stayed empty;
  the only hint was `0 change(s)` in the trace line, noticed two fields later.
  `keyboardVisible` cannot stand in for the check either — it was `0` in the WORKING
  case too, because that device's IME renders no window. So the snapshot now carries
  `isFocused` and `isFocusable` per node (the TOUCH reading — since API 26
  `FOCUSABLE_AUTO` reports every clickable container as focusable, which is exactly the
  false positive here; `canBecomeFirstResponder` / `isFirstResponder` on iOS), `type`
  reads the tree back after its focusing tap and reports
  `focusLanded=self|descendant|ancestor|elsewhere|none|unknown`, and `ui compact` marks
  the focused node ` focused`. `none`/`elsewhere` now **fail** instead of typing into
  the void or into the wrong field; when the resolved node holds exactly one focusable
  input, `type` re-aims at it once and says `retargetedTo=<ref>`; with two it refuses
  rather than guessing. `ancestor` passes — a WebView owns the platform focus while the
  caret is in a DOM input, and so does an `AndroidComposeView` for a Compose
  `TextField`. `unknown` (runtime unreachable, older agent) is reported, never enforced.
  New `scenario.compoundField` in the sample app reproduces the shape, including the
  ambiguous two-input wrapper that must be refused.
- **A selector `tap` re-resolves its point before dispatching, by default.** Resolution
  and dispatch are two steps, and between them the screen can move. `--settle` already
  covered the target that is *animating in*, but the same staleness comes from a
  relayout caused by an EARLIER command — and there a caller has no cue to reach for a
  flag. Measured on a physical device: a `type` shifted the page up 161px, the next
  `act tap --test-id <rowA>` resolved live to the right ref and the right node, and the
  touch — aimed at a rect already stale — opened the bottom sheet of the row BELOW it.
  The command reported plain success both times, and the trace's 101-change diff is
  identical for the right sheet and the wrong one, so only a screenshot of the sheet
  title caught it. Now every selector tap confirms the point repeats before dispatching
  (800ms budget; on a settled screen one agreeing re-resolve ends it) and reports
  `settled=`; when the re-resolve actually moved the point it adds `rectMoved=<dx>,<dy>`,
  so the confirm does not *silently* fix a stale rect — the caller reasoned about a
  screen that had already moved and needs to know. `--settle` now means "this target IS
  animating" and raises the budget to 2s; `--no-settle` opts out to the single-read
  dispatch; a raw `--point` never confirms (nothing to re-resolve). Android and the iOS
  simulator HID path both, since the resolve/dispatch gap is the same on each; iOS
  real-device `activate` is unaffected because it resolves and dispatches in one
  in-process step.
- **`app inject` no longer ANR-kills the app it is injecting into.** The two
  requirements of injection fight each other on a physical device: the main looper
  must RUN for the instrumented method to fire (so the injector nudges input), and
  once it fires JDWP SUSPENDS that thread while the payload dex loads. The queued
  MotionEvent — including the nudge that fired the breakpoint — goes unconsumed for
  the whole suspension, and on real hardware that outran Android's 5s input-dispatch
  timeout: the system killed the process, and Reticle reported a bare `EOFException`
  that reads like a transient glitch and invites a retry that reproduces it.
  The failure is now **classified** instead of surfaced raw: pid gone **and** `dumpsys
  activity exit-info` reporting `reason=6 (ANR)` is reported as the ANR it is, with the
  input-dispatch description and the mitigation. Both halves of the evidence are
  required, so a genuine JDWP fault is never misattributed. The mitigation itself —
  marking the app as being debugged (`am set-debug-app --persistent`), which makes AMS
  relax the verdict — is available as **`app inject --restart-under-debugger`**, and is
  opt-in for a measured reason: AMS FORCE-STOPS the app whose debug marking changes
  (API 36 emulator: `pidof` went from 6356 to nothing), so the flag relaunches the app
  and injects into the fresh process, losing the screen it was on. Doing that silently
  on the one command whose selling point is "into the process as it is running now"
  would be the wrong default — and doing it *without* the relaunch, as an earlier cut
  of this change did, simply broke injection outright: the e2e caught it handshaking
  against a pid the guard had just killed. The skill also now says out loud that
  nudging the app in a loop while injecting is the worst available strategy — Reticle
  sends its own nudge, and an extra queued touch is exactly what trips the timeout.

- **Wheel-picker scenario, on both platforms — and the crash it found.** A wheel is
  the one picker shape the sample apps had no coverage for, and it behaves unlike the
  two they did have: a `Spinner` dropdown materialises real row nodes in a popup, and
  a recycling list binds a row once scrolled, but an Android `NumberPicker` paints its
  unselected values onto the wheel canvas and materialises nothing, ever. So the new
  `scenario.wheelPicker` is deliberately the place the two platforms report
  *different* amounts rather than parity: only the selection is a node on Android,
  while a `UIPickerView` builds a real subview per visible row, so its neighbours are
  nodes a label tap can select and each component's current value comes through as an
  `a11yVirtual` region. Three boundaries went into docs/boundaries.md with it,
  including the one that matters most in practice: `act type` into a `NumberPicker`
  succeeds and *lies* — the tree reads the typed text while the widget's value stays
  put until it validates on focus change, so a wheel must be driven with `swipe`.

  **The crash:** `UIPickerView`'s hidden scroll indicators carry `CGRectInfinite` as
  their frame, and the capture put it on the wire verbatim. Formatting it aborted the
  host process with SIGTRAP (`Int(_:)` traps out of range), so `act swipe` on the
  scenario killed the CLI *after* dispatching the gesture — the report that carried
  the bad frame was lost along with it. Two fixes, because either alone leaves a hole:
  the iOS capture now drops a frame it cannot represent (a 1.8e308-wide rect claims to
  contain every tap coordinate, which is worse evidence than no frame at all, and
  `frame` is already optional on the wire), and every rect formatter in
  `ReticleProtocol` and the host goes through a saturating conversion so a snapshot
  from an older agent cannot kill a renderer either. The guard tests representability,
  **not** `isFinite` — those sentinel components are perfectly finite doubles, which
  is exactly why the obvious check would not have caught this.

## 0.11.0 - 2026-07-27

- **Recording: on by default, and readable.** An action trace already held good
  evidence — two snapshots, two screenshots, a diff — and it was close to unusable.
  Reconstructing a six-action run meant opening six manifests and, every time a
  change named a bare `r102`, the 100KB+ snapshot beside it, because the diff cited
  refs and never said who they were. Nothing summarised a run. And a session with no
  `reticle serve` running recorded nothing at all unless the caller passed
  `--trace-output` by hand, so the ad-hoc runs — the ones most worth reconstructing
  — were exactly the ones leaving no trace.

  Four changes, all on the recording side. **Nothing here asserts:** no replay
  script, no verdict, no pass/fail. `--verify` and `act wait --strict` remain the
  only places an expectation is stated.

  **Every change names its node.** `ActionTraceChange.node` carries
  testId/resourceId/label/role — or the node's text, clipped, when it has no other
  handle — read from whichever side the node exists on, so a node that *vanished* is
  still named. Attached once per ref, so four fields moving on one node cost one
  identity rather than four.

  **The diff is ranked before it is capped.** It was sorted alphabetically by ref
  and truncated at 100, which meant a scrolling list's `frame` churn could fill the
  budget and truncate away the single node that appeared — a correctness bug in the
  evidence, not a formatting nit. Ranking is now by field (appearance, then what a
  user would see, then identity, then the geometry tail) and then by how addressable
  the node is. That second key came out of a real run: on a SwiftUI screen
  transition every appearance ties on field rank, and ref order surfaced six lines of
  `+ r104 [role=container]` describing nothing. The `truncated` marker now carries
  the total, the kept count, and a per-field breakdown of what it shed.

  **`params` records what shaped the gesture.** A `type` trace recorded `chars: 6`
  and no reader could ever say what was typed. An allow-list
  (`ActionTraceParams.RECORDED`) writes `text`, `submit`, `settle`, swipe endpoints
  and the rest; transport keys stay out. `text` is verbatim, and what that costs is
  now stated in docs/boundaries.md rather than left implied: nothing in the capture
  layer marks a field secure, so Reticle cannot tell a password from a coupon code
  and does not pretend to.

  **`reticle trace log`** renders a run as a few lines per action — the same job
  `ui compact` does for a snapshot. Losses are counted, never silent (`…N more` for
  the render, `! manifest kept X of Y` for the capture), and an action that changed
  nothing says so, which is a finding rather than a blank. With no daemon, `act`
  now records into an auto session and prunes to 20 sessions / 2 GB.

  Both diff ports are pinned by a new
  `reticle-protocol/fixtures/action-trace-diff.cases.json` (7 cases + the param
  allow-list), following the selector-resolution precedent. Two bugs the work
  surfaced and fixed: the Kotlin/Swift clip units disagreed by default (UTF-16 vs
  grapheme clusters — now code points on both sides, pinned with an astral-plane
  case), and pruning identified its own sessions by an `auto-` name prefix, which
  would have deleted this repo's own hand-named `auto-trace-e2e` session. Deletion
  is now gated on a marker file Reticle writes, so a session it did not create is
  invisible to pruning whatever it is called.

## 0.10.0 - 2026-07-27

- **Style evidence (`ui style`): the values, their units, their provenance, and the
  properties no channel can read.** The question behind it is "does this screen
  match the design" — spacing, colours, font properties, and whether proportions
  hold on a smaller phone. Reticle answers none of those, on purpose, and the
  roadmap's `diff design` item is **dropped as specified** rather than built: reading
  a design imports an external truth and makes Reticle the arbiter of correct, a
  delta needs a tolerance, and "ignore the status bar" needs an exemption list. All
  three are the consumer's policy; the earlier "no letter grade" caveat only blocked
  the third of the three. A `diff responsive` was considered and rejected for the
  same reason even though it imports no external truth — deciding that a width
  *should* scale proportionally rather than stay a fixed dp IS the design intent. So
  the deliverable is the capability half, and it is the same shape whether the caller
  compares against a design frame, a previous build, or a second device.

  Four things had to be true for that to be useful. **Breadth:** the capture read
  five style properties on a native view and none at all on a Compose node, so a
  Compose screen — where new Android UI is written — answered nothing a design asks
  while the identical `TextView` screen answered everything. Text style now comes
  from the `GetTextLayoutResult` action's `TextStyle`, the same public channel
  `ComposeTextRegions` already used for link geometry, reached by name-prefix
  reflection because a getter returning an inline value class (`TextUnit`, `Color`)
  carries a mangled JVM name. Verified against Material 3's published type scale on
  a live emulator: `bodyLarge` reports 16sp / 24sp line height / 0.5sp tracking and a
  Button's `labelLarge` reports 14sp / weight 500 — the numbers match the spec, which
  is what proves the value-class unpacking is right rather than merely non-null.
  Padding joined too, because a frame-to-frame gap cannot say whether the space
  belongs to this view, its neighbour or their parent, which is exactly what a
  spacing spec states.

  **Units**, and this is where the silent bug lived. The Android view tree measures
  in physical pixels; UIKit measures in points, which are already
  density-independent. Dividing an iOS point by `density` again would halve every
  length while looking perfectly plausible, so `StyleUnits.lengthsAreDensityIndependent`
  is the one place that difference is decided and the shared fixture pins both
  directions. Text additionally renders in sp, which divides out the new
  `ScreenInfo.fontScale` — without it "the app asked for the wrong size" and "the
  user enlarged text" are one observation, and an unprobed font scale says
  `sp:unprobed` rather than assuming 1.0.

  **Provenance:** `Node.styleChannels` names the channel per property, because a
  live `viewField` read and a value reflected out of a background `Drawable` are not
  equally trustworthy, and it doubles as the allowlist of which `custom` keys are
  style at all. **Gaps:** `Node.styleGaps` lists properties a node HAS and no
  channel can read, with a reason — the boundary rule at property granularity, since
  a missing key otherwise reads as "the app set nothing". Two exist today and both
  are in `docs/boundaries.md`: Compose `background`/`clip`/`border` are draw
  modifiers with no semantics projection (reflecting the `LayoutNode` modifier chain
  was rejected as unverifiable against a public contract), and an Android `Typeface`
  names no family.

  **The DOM is the third channel**, tagged `computedStyle` by both bridges so a
  WKWebView and an `android.webkit.WebView` answer alike. It behaves deliberately
  unlike the native two: values pass through verbatim with their own suffixes,
  because a CSS `px` is neither a device pixel nor a UIKit point and a page's zoom is
  not observable from in-process, so converting would be arithmetic on an assumption.
  And because `getComputedStyle` answers for every property whether or not the page
  stated it, a computed value equal to its CSS initial (`auto`/`none`/`0px`/`static`)
  is dropped — the exact analogue of a null Android background emitting no key. That
  is the difference between 26 lines per DOM node and 6. Inherited values are
  deliberately NOT suppressed even though typography repeats down a subtree: a design
  states "this button's label is 14px", and a button inheriting 14px from `body`
  would then show nothing on the very node being asked about.

  `StyleObservation` in `reticle-core`, mirrored in `ReticleProtocol`, owns the
  derivation AND its text rendering — both host renderers just call `render()`, so
  the Kotlin helper and the Swift host cannot format one snapshot two ways, which is
  how the two `compact` renderers drifted before. Pinned by
  `reticle-protocol/fixtures/style-observation.cases.json` from both languages, plus
  new e2e assertions on both platforms.

  One altitude decision is worth naming because it looks like data loss and is not.
  A node whose every style property sits at its platform default is skipped by the
  **text** view: an Android `ViewGroup` reports four paddings and an elevation
  whether or not anyone set them, and on a real screen that produced a seven-line
  block per wrapper and buried everything real (iOS was worse — `alpha 1.0` on all
  40 nodes). But once a node has any style, all of its properties print, zeros
  included, because "the app sets padding 0 and the design says 16" is precisely the
  finding this exists to support; a declared gap always keeps a node; and the
  structured `items` keep every value regardless, as does `ui node`.

- **Four stale surfaces and two duplications, all the same shape as the README
  ones.** All four plugin manifests still sold "a runtime UI evidence + action
  harness for **Android** apps", with `ios` missing even from the keyword list —
  the text a user reads before installing. The three slash commands restated the
  skill's workflows in their own words, mentioned no iOS, and had already drifted
  (`report.md`'s health-check list was a stale subset of the skill's table); they
  are now thin wrappers that name the skill as the source and keep only what is
  command-specific, including the evidence markers a caller must relay rather than
  smooth over. `docs/ios.md`'s boundary section and `docs/boundaries.md` covered
  overlapping facts at different depths with no link either way, so both read as
  complete; each now says what the other is for — index of facts vs. the mechanism
  behind the platform-specific rows. And `AGENTS.md`'s second Toolchain list, which
  had already diverged from the README's in both directions, is now a pointer plus
  the three build-specific pins.

  Two roadmap items were falsified by the preceding work and are recorded as such.
  The **codegen trigger already fired**: "a drift bug the schema tests fail to
  catch" is exactly what the seven selector-resolution drifts were — none of them
  wire shape — and it was answered with a shared fixture, which is the cheaper
  answer while the drifting surfaces are behaviour tables rather than models.
  Writing that down keeps it from later reading as an oversight. The
  `Injector.kt` docs-debt item was real: `connectWithHandshake` now carries its own
  KDoc for the three load-bearing details of its retry loop, while the measurement
  rationale stays on the budget constant it actually explains.
- **Both READMEs describe the same product again — and it is not an Android-only
  one.** The primary README still opened on Android, tabled Android mechanisms, and
  listed modules with no `reticle-swift`, no `reticle-agent/ios` and no
  `sample-app-ios`, while asserting two things iOS had already falsified
  ("`reticle-agent/` is reserved for future per-platform agents"; "the host owns no
  device code"). iOS survived only in three Quick Start code comments.

  The pair had also drifted **both** ways, which is worse than a lagging
  translation: the English file had no `replay flow` at all, the Chinese one no
  `act batch`, no helperd warm path or `--helper-broker`, no `status` advisories, no
  proxy body cap, no pointer to the boundaries table. Both now carry the same twelve
  sections and the same feature set.

  Trimmed while doing it: "How it works" is one Android/iOS table; the 150-line
  `Local session event bus` grab-bag splits into the session bus, warm paths and
  routing, traffic rules **and flow replay**, and batching; the web panel's 16-line
  description becomes four lines plus a pointer, because `events.md` already
  documented the same surface in more detail; Quick Start keeps every command but
  its six paragraph-long rationale comments shrink to a line each, the reasoning
  being in `architecture.md` already; and `Releases` moves to `AGENTS.md`, which
  owns the packaging rules.

- **The host's platform interface is typed; JSONL is back to being Android's
  transport.** Every command used to be issued through one stringly-typed call —
  `call("uiReport", ["package": pkg])`, returning `[String: Any]`. For Android that
  shape is real: the call crosses a process boundary as JSONL. But the transport's
  shape had been promoted into the *domain* abstraction, so the natively in-host iOS
  backend paid for a wire it does not have — a 30-case switch over method-name
  strings, 46 `as?` unpacks, and a mistyped key discovered at runtime on a device
  instead of at compile time on a laptop. Meanwhile `ReticleProtocol` already had
  typed models the host was carefully re-wrapping in dictionaries.

  `HostBackend` is now the domain interface: one method per capability, typed
  requests, typed results. Two implementations — `AndroidBackend`, which is the
  **only** place the helper's method names and parameter keys are spelled and the
  only place its replies are unpacked, and `IosHelperClient`, which implements the
  interface directly and no longer speaks a wire at all. `HelperCalling` survives as
  exactly what it is: the JSONL transport, shared by the three Android transports
  (spawn, resident helperd socket, `serve --helper-broker`) that differ only in how
  the envelope travels. `serve`'s device-proxy calls are typed too, so the daemon no
  longer assembles `["keychain", …]`-style argv or `proxySet` params by hand.

  Two places keep an untyped escape hatch, both on purpose and both documented at
  the declaration. `act`'s **result** stays open (`ActOutcome.raw`): this is an
  evidence tool, a gesture reports gesture-specific facts (`settled`, `submit.via`,
  `wasVisible`, `settleSkipped`), and a closed struct would mean a new fact cannot
  reach the user until the host is edited too — so it is typed where a *decision* is
  made (a wait's three-state outcome, `--strict`'s exit code, a batch gate, whether
  to publish a trace) and open where it is *displayed*. And an `act batch` step's
  unrecognized keys are forwarded rather than dropped, so a step written against a
  newer helper still reaches it.

  Behaviour is unchanged: same wire, same stdout, same `--json` shapes.

- **The iOS platform backend is its own target, so the layering below
  `ReticleHostCore` is now the layering above it too.** `ReticleHostShared` →
  `ReticleNetworkLane` → `ReticleHostCore` was split apart precisely so the capture
  engine could not reach up into the daemon, and the compiler enforces it. Above
  that line, one 6.7k-line target still held the CLI, the daemon, four route
  groups, the panel, and the entire iOS platform implementation — the discipline
  was real but rested on habit.

  `ReticleHostIos` now holds the six `Ios*` files and depends on **nothing above
  it**: shared types, the protocol, and the HID C target. Two consequences the
  compiler now guarantees rather than the reader hoping: the daemon cannot reach
  into platform code, and a platform backend cannot reach up into the CLI. The two
  places that legitimately crossed the line are now explicit — `HelperCalling` and
  the version constant moved down into `ReticleHostShared` (a backend must be able
  to implement the call surface and name itself without importing the CLI), and
  `serve --proxy-install-ca`, which used to assemble `["keychain", udid,
  "add-root-cert", …]` inside the daemon, now asks for the capability
  (`Simctl.trustRootCertificate`) and lets the platform own the argv. Exactly two
  symbols are public upward. `ReticleHostCore` `@_exported`s the new target, so
  every `import ReticleHostCore` is unchanged.

  What is left in `ReticleHostCore` is grouped by concern —
  `Daemon/`, `CLI/`, `Android/` — and the two files that had grown past reading
  size are split along the seams their own `// MARK`s already drew:
  `IosHelperClient` 956 → 614 lines plus `IosScrollTo` / `IosVerify` / `IosParams`,
  and `LoomCaptureLane` 981 → 849 plus `LoomRuleTranslation` (the lane's one
  genuinely pure part: a total function from Reticle's rule/filter model to Loom's,
  and the part with unit tests).
- **One selection point for the four helper backends, instead of four copies of the
  same error handling.** `runHelperBacked` had a branch per backend (iOS in-host,
  `--use-daemon` broker, the resident helperd hot path, a direct spawn), and each
  branch carried its own `do/catch` with the same `JsonEnvelope.enabled` fork — four
  chances for one of them to drift. Worse, client teardown was per-branch and
  differently named (`shutdown()` / `close()` / nothing), so only two of the four
  released anything.

  `HelperCalling` now declares `close()` with a default no-op, so a backend that
  owns no transport says so by inheriting it, and the CLI can `defer { client.close() }`
  once without knowing which backend it got. Backend choice moves into
  `makeClient(args:serial:)` — the priority order (iOS → broker → helperd → direct
  spawn, with helperd bring-up failure falling through rather than failing the
  command) is now readable in one place instead of inferred from nesting. The
  no-helper-binary case keeps its distinct exit code 2 and plain-text message via a
  `HelperUnavailable` error, because a missing helper is a setup problem rather than
  a call that failed — there is no RPC result to envelope.
- **The Honest boundaries table is its own document (`docs/boundaries.md`).** It had
  grown into a third of `architecture.md`, which was therefore three documents in
  one: a design explanation read once, a tutorial, and a reference table consulted
  per case. They have different read patterns and different edit patterns — every
  new boundary appends a row here, and nothing else in the architecture doc changes
  that often.

  Pure move: the marker vocabulary, the boundary table (what is unreachable, why,
  what Reticle emits instead, what pins it) and the `act wait` mapping are unchanged.
  `architecture.md` keeps a pointer plus the one rule the rest of it depends on — an
  unreachable thing must produce evidence naming itself, never silence — and every
  cross-reference in README, AGENTS.md and both roadmaps now points at the new file,
  since that is where a boundary must be recorded.
- **Selector resolution was two implementations of one rule, and they had drifted
  in seven ways. Now there is one table, and both read it.** The action path
  (`act tap`, and `act wait`'s success test) resolves in Kotlin for Android and in
  Swift for iOS, because the two hosts are different programs. That is fine; what
  was not fine is that nothing pinned them together, unlike `act wait`'s outcome
  table, which has been fixture-driven from both sides for a while. Measured
  differences, every one of them a case where the same command aimed somewhere else
  depending on the platform:

  1. **iOS never consulted the semantic tree.** The documented rule is
     "semantic-first for movement and input, view frames only as a fallback";
     iOS resolved straight off the view tree.
  2. **A `--region` miss meant different things.** Android fell through to a
     whole-node tap; iOS failed. Android's behaviour is now the one that changed:
     on an agreement row the node's centre is the *checkbox*, so "I could not find
     the phrase you asked for, so I tapped something else and reported success" is
     the worst available answer. It now refuses, naming how many regions and
     whether a char grid exist. `act wait` treats that refusal as an honest
     negative (the phrase has not rendered yet), never as an ambiguity.
  3. **Region labels matched case-insensitively on Android, case-sensitively on
     iOS** — so `--region "terms"` found the span on one platform and fell through
     to the char grid on the other, landing on a different rect. Canonical:
     labels case-insensitive (the platform often normalizes them), the char grid
     verbatim (it maps on-screen text in any language, and case-folding is
     locale-dependent).
  4. **Selector precedence differed between the two paths inside the Kotlin
     resolver**: the region path tried `ref` first, the whole-node path `testId`
     first, so `--test-id X --ref Y` picked a different node depending on whether
     `--region` was also passed. One order everywhere now: `testId` →
     `resourceId` → `cssSelector` → `ref` → `label`.
  5. **First-match lookups iterated an unordered map.** In Kotlin that is the
     serializer's key order (not a contract); in Swift a `Dictionary`'s order is
     hash-seeded **per process**, so an app repeating a `testId` resolved to a
     different node between two runs of the same command. Both sides now walk the
     tree in document order (DFS from the root, then orphans sorted).
  6. **iOS reported `source: "selector"`** where Android reported
     `semantic:testId` / `region:span` / `charGrid:approx`. The trace lost exactly
     the distinction an agent needs — a char-grid approximation is not a semantic
     hit. iOS now emits the shared vocabulary, plus the resolved `ref`.
  7. **`act wait` on iOS probed a different resolver than `act tap` did**, while
     the wait's whole contract is "a resolved wait guarantees the next act
     resolves the same way". Both now call one resolver.

  The new authority is `reticle-protocol/fixtures/selector-resolution.cases.json`
  — a snapshot plus 22 cases, read by `SelectorResolutionContractTest` (Kotlin) and
  `SelectorResolutionContractTests` (Swift). iOS's inline walk is replaced by
  `SelectorResolution` in `ReticleProtocol`, so the Swift host and the iOS agent
  share it the way they already share the models.
- **The Kotlin `Platform` SPI is gone — it was an extension point its own decision
  record had already closed.** `Platforms.current(target)` accepted a `--target` /
  `RETICLE_TARGET` selector so "the selection point exists before a second platform
  lands". A second platform landed, and it went somewhere else: iOS is native in the
  Swift host (`ReticleCLI.swift` picks the target), because a helper exists **only**
  where a platform's dirty-work lives outside the host's ecosystem — JDWP does, and
  `simctl`/DYLD do not. Every one of the 20+ call sites passed no target and no code
  ever read `RETICLE_TARGET`, so the parameter was dead and the abstraction was
  advertising a portability it will never have.

  Deleted `Platform`, `Platforms` and `AndroidPlatform`; device construction is now
  the single `Adb.forSerial(serial)` (which keeps the `$ANDROID_SERIAL` fallback),
  so a call site reads `Adb.forSerial(...)` instead of `Platforms.current().device(...)`.
  `DeviceController` / `InputDispatcher` / `AppInjector` stay — they name real seams
  and carry the KDoc — but they now say what they are: internal seams of the Android
  helper, adb-shaped on purpose. A retired extension point is worse than none,
  because the next contributor plans against it.

- **The capture lane no longer loses flows quietly.** `handle` — which writes body
  and frame artifacts to disk — ran inline in the `for await` over Loom's flow
  stream, making that loop the slow consumer of an `AsyncStream` buffered with
  `.bufferingOldest(512)`. A traffic burst therefore dropped the *newest* flows, and
  `AsyncStream` gives a subscriber no way to find out. A gap in the evidence was
  indistinguishable from traffic that never happened, which is the one thing this
  lane must never allow.

  The stream is now drained immediately onto a serial worker, so the engine is not
  back-pressured into dropping anything. The worker's backlog is bounded (4096
  flows — an unbounded one is a memory leak with better manners) and, unlike the
  stream, it can count what it drops: a new `network.advisory` event reports
  `capture-backlog-overflow` when recording starts falling behind and
  `capture-backlog-recovered`, with the episode's loss count, once it catches up.
  Two edges rather than one event per dropped flow, so a drop storm does not become
  its own flood; the overflow edge deliberately omits a count, because while the
  episode is open the size of the gap is not yet knowable.

  **Still silent, and now written down as such:** if Loom's stream buffer ever drops
  despite being drained instantly, that loss remains undetectable from this side —
  `AsyncStream` carries no signal for it. Closing that needs a dropped-flow counter
  in Loom. Both facts are new rows in the Honest boundaries table, including the
  unobservable one, which is listed rather than implied by its absence.

- **Three capabilities Loom 0.0.5 opened up: timing splits, WebSocket frames, and
  finding a flow to replay.**

  **`ttfbMs` / `receiveMs` on every response.** "This call is slow" has a different
  cause depending on which half it lands in, and `durationMs` alone cannot say
  which. A response event now carries when the head came back (`firstByteMillis`)
  and the two spans it splits the exchange into — server think-time and body
  transfer — which sum to `durationMs`. A flow that failed before any head reports
  neither rather than inventing one from the completion stamp.

  **WebSocket frames are evidence now, not a 101 and a shrug.** An upgraded socket
  used to leave a `network.request`/`network.response` pair and nothing else, with
  every frame Loom captured dropped on the floor. Frames now arrive as
  `network.websocket` events under the socket's `requestId` — one per frame, in
  order, both directions, with a text preview inline and the whole payload as an
  artifact only when it is too big to sit there. Emitted as they arrive rather than
  summarized at close, because a socket may outlive the session and a summary that
  never comes is not evidence.

  Two caps sit above that and both say so: Reticle stops at 1000 frames per socket
  so one chatty socket cannot bury the session, and Loom stops at 10k frames / 5 MB.
  Either way one `capReached` event names what was recorded and what was dropped —
  **the socket is still open and still talking, and the silence afterwards must not
  read as a quiet socket.**

  **`GET /sessions/current/flows`** filters the capture engine's retained flows so
  an agent can name the exchange it means without pulling every summary into
  context; the scan runs over everything retained and only then applies `limit`, so
  an older match is still findable. Scoped, deliberately, to what can still be
  *replayed*: every result is stamped `replayableOnly: true`, because the ring is
  bounded and `events.jsonl` is the evidence. An empty list means "nothing
  replayable matches", never "this never happened".

  New Honest boundaries rows for the frame caps and for flows aged out of the replay
  buffer. `network.websocket` has its own typed payload schema, golden fixture, and
  Kotlin contract test; the Swift schema-pin test — which had been passing vacuously
  because it never set the new fields — now covers the nested replay diff too, and
  caught a real miss: `bodyComparisonPartial` was never being written into the
  emitted event.

- **Loom 0.0.1 → 0.0.5, and the two behavior changes that came with it.** Loom
  renamed its SPM targets to match its products (`LoomProxyCore` /
  `LoomSharedModels`), so the lane's imports change; nothing else in the engine's
  surface broke. The two changes worth more than a version bump:

  **A capped body no longer reads as a whole one.** Loom now reports the true wire
  size when its own capture cap clipped a body before Reticle ever saw it
  (`fullBodyBytes`) — previously it stopped recording without recording that it had
  stopped, and Reticle, whose cap is not the only one in the chain, dutifully
  reported the prefix length with `truncated: false`. Capture events now carry the
  real transfer size, and the replay diff carries `bodyComparisonPartial`: under it,
  `bodyChanged: false` means the recorded prefixes match, not that the responses do,
  and `isIdentical` refuses to fire at all. Differing wire sizes still assert a
  change, since that much is knowable from a prefix. A false "nothing changed" on a
  replay is the worst thing this lane could emit; it now says "I could only see the
  first megabyte" instead. New row in the Honest boundaries table.

  **A rejected rule is named instead of dropped.** `setRules` used to be atomic and
  throw; it now applies every rule that validates and reports the rest. Reticle was
  discarding that report, which would have let an agent add a mock, get no error,
  and watch live traffic sail past. Each rejected rule is now named on stderr, with
  the engine's reason, as NOT active.

- **`act wait`: cross an async boundary without a blind sleep, and get a
  three-state answer.** The only `act` gesture that dispatches no input. Predicates:
  `--for <selector>` (appear), `+ --gone`, `+ --text <substring>`, or `--idle` for
  the screen itself going quiet — the one to use when you do not know the next
  screen's selectors yet. `--for` reuses `--verify`'s token grammar rather than
  inventing a second spelling. It refuses `--point` (a raw coordinate always
  "resolves", so there is nothing to wait for) and `--alias` (an alias describes the
  screen a wait exists to watch change), each by name. Works on real devices: no HID
  surface is involved, so it sits beside `hide-keyboard` rather than `tap`.

  **The success test is resolution through the act's own path, not `isVisible`.**
  An earlier `wait --for appears` proposal was dropped in this repo over exactly
  that proxy (the reason is recorded on `HelperScrollTo` and `settleInputTarget`),
  and this one only earns its place by carrying the guarantee the proxy could not:
  a `resolved` wait means the very next `act` resolves the same way. Visibility and
  occlusion are reported as **caveats** (`resolved-but-not-visible`,
  `occluded-by:keyboard` plus the command that clears it), never as a downgrade —
  "can the next act target it" and "can the user see it" are different questions,
  and a keyboard-covered submit button is a real answer to the first.

  **Existence is three-state**, which is the part nothing else here could do:
  `resolved` / `absent` (a miss nothing prevented seeing — a caller may act on it) /
  `unknowable` (a miss that could not have been observed: lost window focus, a row a
  recycling list has not bound, an unreadable DOM, an unsupported WebView kernel, a
  screen that never settled, a `--label` the resolver refused to disambiguate).
  Collapsing the third into the second is how a runtime observer lies — an agent
  reads `absent` as "this feature is broken". Measured on the real thing: a genuine
  app failure (a tap that did not raise its dialog) reports `absent` 3 times out of
  3, while all four unknowable causes report `unknowable` on both platforms.

  The outcome is a **field**; `--json` stays `{"ok":true}` on a timeout, because a
  predicate that did not come true is an observation, not a tool failure. Exit codes
  are an opt-in lossy projection for shell/CI (`--strict`: 3 = absent, 4 =
  unknowable, deliberately distinct — a non-zero exit otherwise reads as "the
  command broke" to an agent driving this through a shell). A batch step may set
  `"strict": true` to become a gate.

  `WaitVerdict.classify` lives in `reticle-core`, mirrored in `ReticleProtocol`, and
  BOTH platforms' suites are driven by one table —
  `reticle-protocol/fixtures/wait-classification.cases.json` (26 cases). That is the
  anti-drift device the feature needed: `scroll-to`'s settle logic is two
  hand-written implementations of one idea, and it drifted.

  Two defects the e2e caught that the unit tests could not, each now pinned by a
  regression test: the CLI silently dropped `--point`, making the helper's by-name
  refusal unreachable; and scroll travel was not scoped to a window, which made
  `absent` nearly unreachable on any app with a scrolling home screen and produced
  actively misleading advice (`scroll-to --css …` for a DOM element behind a
  blocking JS modal). Scroll doubt is now scoped to the **topmost** window, and
  `next:` lines are ordered most-specific-first.

- **Docs: the roadmap is a roadmap again.** It had grown to ~1000 lines in which
  settled decisions, finished work, design sketches and open items were interleaved,
  so "what is actually left?" could not be answered without reading all of it. Now
  377 lines with one job per section: the goal and its scope constraints, a
  current-state table, **`What's left` — the only to-do list in the file**, ordered
  by leverage with a size and how well each item's cause is established (measured /
  by construction / neither, and "neither" means reproduce it first), then
  `Decisions of record`, `Investigated and dropped`, and the completed
  boundary-case sweep.

  Cut by deduplication rather than by deletion of substance: the event envelope and
  taxonomy live in `reticle-protocol/events.md`, the honest-boundary list in
  `docs/architecture.md`, the module map in `AGENTS.md`, the helper RPC contract in
  `reticle-protocol/helper-rpc.md` — the roadmap now points at each instead of
  carrying a second copy that could drift. Every decision kept its *why*. The
  Chinese roadmap was regenerated against the same structure (it had been stale
  since 2026-07-23), and inbound references from `DESIGN.md`,
  `docs/architecture.md`, `reticle-protocol/helper-rpc.md` and
  `reticle-host/Package.swift` now name sections that exist.

- **Honest boundaries, collected in one place.** Everything an in-process observer
  structurally cannot reach — closed shadow roots, cross-origin iframes, third-party
  WebView kernels, bitmap-baked text, pure-Canvas controls with no accessibility
  surface, out-of-process system UI (permission prompts, biometric sheets, share
  sheets, Custom Tabs / `SFSafariViewController`, the IME), the screenshot's blind
  spots, DRM surfaces, non-debuggable release builds, real-device iOS input — now sits
  in one table in `docs/architecture.md`, each row paired with **the evidence Reticle
  emits instead** and **the scenario that pins it**. Rows that nothing exercises say
  so out loud (cross-origin frames need a second origin; there is no DRM sample),
  rather than letting a missing test read as coverage. The skill carries the
  agent-facing half: what each marker means and what to do instead of retrying.

  One claim was upgraded from theory to measurement while writing it: a **closed**
  shadow root now sits beside the open one in the complex web fixture, and the suite
  asserts the difference — the open root is pierced, the closed root's content is
  absent, and the closed host element is still captured at its own rect. An asserted
  absence, so silence there can never be mistaken for capture.

- **A third-party WebView kernel now says its own name.** `WebViewBridge` is typed on
  `android.webkit.WebView`, so an X5/TBS or UC kernel — a class that *calls* itself a
  WebView but is not the platform one — cannot be attached to: no `--css`, no styles,
  no piercing, at any level. Until now that was indistinguishable from a page that
  happened to be empty.

  A reflective adapter was considered and **rejected**: it cannot be verified without
  a real kernel sample, and an unverifiable bridge that silently returns nothing is
  worse than a stated boundary. So the deliverable is the label, not the capability:
  the node carries `dom:unsupported-kernel` with `custom.domKernel` naming the class
  that triggered it, and a `--css` miss on that screen explains that no selector can
  ever match there. It is kept distinct from `dom:unavailable` on purpose — that one
  says "could not read it just now" (retry may help), this one says "there is nothing
  to read" (retrying is pointless).

  The rule is the SHAPE, not a vendor list, so it needs no upkeep: a class named
  WebView that is not `android.webkit.WebView` and wraps no real one. `scenario.foreignKernel`
  pins it with a self-drawn stand-in beside a REAL WebView, since the contrast — one
  marked, one still serving its DOM — is what makes the marker mean anything. iOS has
  one web engine, so this cannot arise there.

- **The screenshot's blind spots are labelled, not left blank.** A picture is trusted
  more readily than a tree, so a silent omission in one is the worst kind of evidence.
  Measured on an emulator with a new `scenario.screenshotDegrade`, the two capture
  paths fail in exactly complementary ways:

  | | in-process (`agent /screenshot`) | device (`adb exec-out screencap`) |
  | --- | --- | --- |
  | `SurfaceView` content | **missing** — rgba `0,0,0,0`, a transparent hole | present (`255,0,255`) |
  | `FLAG_SECURE` window | present, unaffected | **blanked** — `0,0,0,255` |

  So the `SurfaceView` node now carries `pixels:unavailable` and the secure window
  `screencap:blank` (compact renders both), and `reticle ui screenshot` prints a
  `degraded:` line naming what the picture it just wrote is missing and which path
  would show it. iOS gets the same marker for a different cause, also measured: the
  keyboard's host window refuses to render into a borrowed context, so the agent's
  picture shows the app's plain background where `simctl io screenshot` shows the
  keys — the capture already skipped that window, it just never said so.

  Both suites assert the labels AND the pixels behind them (crop with `sips`, decode a
  1x1 PNG), so the markers cannot quietly become decorative.

- **SwiftUI `Text` links are addressable (iOS).** A markdown `Text` ("Read the
  [Terms](…) and [Privacy](…)") is ONE accessibility element with one label — no
  `UILabel`, no `NSAttributedString.link` run, no child element, no view to measure —
  so every `RegionProbe` channel came up empty and the two links were unreachable,
  while the UIKit agreement row beside it decomposed fine. (Android's Compose twin was
  fixed earlier in the same sweep.)

  Before building, the alternatives were measured and ruled out: child accessibility
  elements (0), `accessibilityElementCount` (0), custom actions (none), a usable
  custom rotor (none), and every `_accessibility*` link accessor probed (unresponsive).
  What DOES exist is `accessibilityAttributedLabel`: the label split into runs
  carrying `UIAccessibilityTokenLink` on the link ranges plus per-run font tokens —
  system-emitted attributes on a public property, not SwiftUI internals.
  `SwiftUITextRegions` re-lays those runs out with their own fonts inside the
  element's screen frame and emits per-link `span` regions plus a char grid, so
  `act tap --region "Privacy"` works — and a non-link substring is targetable too.

  The geometry is **reconstructed, not read**, which is why the iOS suite asserts it
  by consequence: it taps each recovered rect and checks which URL the app's `openURL`
  handler actually received ("opened terms" vs "opened privacy"), so a plausible-but-
  wrong rect fails. The SwiftUI scenario had no e2e coverage at all before this.

- **`act tap --settle`.** Resolution and dispatch are two steps, and a target that is
  still sliding in moves between them: measured on an emulator (1 run in 5), a
  `PopupMenu` row was captured at y=1396, the tap resolved y=1474, the menu came to
  rest at y=1612 — and `--label "Delete item"` fired **"Menu: Rename"**. A silent
  wrong tap is the worst failure shape this project has, so `tap` can now opt into the
  stabilize step `act scroll-to` already performs: re-resolve the selector until its
  point repeats, then dispatch, and report `settled` (false = still moving when the
  `--settle-timeout`, default 2s, lapsed, so the point may already be stale). It never
  refuses to tap and it needs a selector — a raw `--point` has nothing to re-resolve,
  which is an error rather than a silent no-op. Both platforms; the Android suite
  dropped its two `sleep 1` workarounds for it.

  Its limit, measured and worth knowing: `--settle` watches the resolved POSITION. An
  iOS `UIAlertController` animates in with a transform/alpha while its accessibility
  frame is final from the first capture ([205,463 140x48], unchanged across six
  captures) — so settle honestly reports `settled=true` at once, and a tap dispatched
  right then still does not land (three runs). "The position stopped moving" is not
  "the view is hit-testable yet"; there, wait or `--verify` and retry. This is the
  narrow, resolution-path version of the settle problem, which is why it does not
  revive the dropped `wait --for appears` proposal.

- **New evidence: `screen.windowFocused`.** A system permission prompt, a biometric
  sheet, an autofill dialog — each belongs to ANOTHER process, so it appears in no
  window of this app and in no node of the tree. Measured during this work: with the
  Android permission prompt up, `mCurrentFocus` was
  `com.google.android.permissioncontroller/...GrantPermissionsActivity` while the
  capture still listed every control as `tappable`. That is the worst shape of
  wrongness this project guards against — a confident, ordinary-looking observation
  while input goes somewhere else entirely. Reticle cannot show what is on top
  (structurally out of reach), but it can report the FACT that this app's window no
  longer has focus: Android reads `View.hasWindowFocus()`, iOS reads
  `UIApplication.applicationState`, and `ui compact` leads with
  `window: UNFOCUSED — another window has input focus …`, above even the keyboard
  line, because nothing in the tree is actionable in that state.

  Worth recording alongside it: the in-process SCREENSHOT is blind to that window
  too — with the iOS notification alert up, the agent's screenshot showed only the
  app's own Checkout screen while `xcrun simctl io screenshot` showed the alert
  plainly. So "does the screen look right" fails the same way the tree does;
  `windowFocused` is the one signal that doesn't.

- Sample apps + e2e: a **system permission prompt** scenario on both platforms
  (`POST_NOTIFICATIONS` on Android, `UNUserNotificationCenter` on iOS). Both suites
  now assert the same lifecycle: the app holds focus beforehand, loses it while the
  prompt is up (with `window: UNFOCUSED` leading the compact while the app's own
  controls are still captured as `tappable` — that IS the trap), no node from the
  other process leaks into the tree (the boundary, asserted so silence is never
  mistaken for capture), and the evidence clears once the prompt is answered.

  Making the iOS half assertable took two measured workarounds, both documented in
  `scripts/e2e-ios.sh`. The prompt cannot be **re-armed** with
  `xcrun simctl privacy … reset notifications` (it fails outright, "Operation not
  permitted"), so the section re-INSTALLS the app bundle, which does reset the
  authorization to `notDetermined` — and therefore runs LAST, since that wipes the
  app's container. And an open alert cannot be **answered** from the host
  (`simctl privacy grant` -> "Operation not permitted"; terminating the app leaves the
  alert standing) while a stuck one silently swallows every later HID tap, so the
  suite answers it with a coordinate HID tap at the alert's fixed layout position
  (~57% of screen height, ~32% deny / ~68% allow of its width — no text is read, so
  the simulator's language does not matter) inside an answer→retry→re-check loop.
  `permission.status` flipping to "Prompt dismissed" is the proof the tap reached the
  alert rather than the alert merely going away.

- **Fixed: window-vs-window occlusion never fired on iOS.** Every `UIWindow` was
  captured as `kind = .view`, and `CompactObservation` computes occlusion by walking
  the application node's WINDOW children in stacking order — so an overlay window
  covering the screen left the controls beneath it looking perfectly tappable, which
  is the precise silent wrongness the occlusion work exists to prevent. (Measured:
  `r1 kind=view role=window UIWindow`.) `UIWindow` nodes are now `kind = .window`,
  and a control under an overlay window reports `occluded-by:<windowRef>` exactly as
  on Android — with one deliberate exception found by the fix itself: the keyboard's
  host windows (`UIRemoteKeyboardWindow` / `UITextEffectsWindow`) span the WHOLE
  screen even though the visible keys occupy the bottom strip, so treating them as
  occluders marked every node on screen occluded, including nodes well above the
  keyboard. Keyboard coverage keeps its own exact channel (`screen.keyboard` +
  `occluded-by:keyboard`), which also clears the instant `act hide-keyboard` runs,
  whereas the window can linger. The `UIAlertController` case remains without occlusion because iOS
  presents an alert INSIDE the presenting window — a presentation difference, not a
  missing capability, and the e2e now says so instead of implying a gap.

- Window scoping for `--label` and `act scroll-to` now prefers the highest-stacked
  window that CONTAINS a candidate, rather than the topmost window outright. Making
  `UIWindow`s real windows activated those filters on iOS, where the system keyboard
  is itself a window in the scene — a strict "top window only" rule would have
  emptied the candidate set whenever the keyboard was up.

- Sample app + e2e (iOS): an **overlay window** scenario — a real second `UIWindow`
  at `.alert` level over the screen. Asserts nothing is occluded before it exists,
  the control beneath is `occluded-by` once it is up, the overlay's own content is
  captured, its dismiss button is reachable by `--label` (window scoping and all),
  and the occlusion CLEARS when it goes away.

- **A blocked DOM bridge now says so: `dom:unavailable`.** A web page can raise a
  NATIVE modal from JavaScript (`alert()` / `confirm()`), and that blocks the
  page's JS thread until the app dismisses it — so `evaluateJavascript` can never
  call back and the DOM read times out. Verified the bridge already degrades
  correctly (capture returns in ~1s, the WebView stays an opaque node, the modal's
  own content is captured), but the degrade was SILENT: "no DOM nodes" and "this
  web view is empty" were the same observation, which is also what made a
  lottie-animation flake read as "the tap didn't land". Both agents now mark the
  host node `custom["domStatus"] = "unavailable"` whenever a DOM read fails, and
  `ui compact` renders it as `dom:unavailable`.

- Sample apps + e2e: a **web JS dialog** scenario on Android — a page whose button
  calls `alert()`, with the app implementing `onJsAlert` as real apps do. Asserts
  the capture does not hang (~1s), the native modal's message is captured, the DOM
  is absent AND labelled `dom:unavailable`, and that dismissing it (via
  `--label "OK"`) lets the page's own JS continue.

  iOS gets the same code path through a different trigger, and the reason is worth
  recording: measured on iOS 26.3, a page's `alert()` **never reaches the app's
  `WKUIDelegate`** in this configuration — the controller is alive, `uiDelegate` is
  set, no `deinit` fires, and the statement after `alert()` runs immediately, so
  WebKit simply skips the panel. (Disabling content JavaScript is not a substitute
  either: the app's own `evaluateJavaScript` still runs and the DOM reads fine.) The
  iOS scenario therefore has the page block its own JS thread with a bounded busy
  loop — the same condition an `alert()` creates, deterministic, and self-clearing
  so recovery is asserted too: `dom:unavailable` appears, native content on the same
  screen is still captured, and the marker CLEARS when the loop ends. A JS modal
  that does appear on iOS is an app-presented `UIAlertController`, already covered
  by the system-dialog scenario.

- e2e: the popup-menu step now waits for the popup's enter animation before tapping.
  `wait_compact` returns the moment a row is first captured, which can be
  mid-animation — the rect is then stale by dispatch time and the touch lands on the
  neighbour (measured: `--label "Delete item"` produced `Menu: Rename`). Reticle
  reports positions faithfully; it cannot hold a moving target still, so the caller
  waits. Tracked separately: an opt-in `act tap --settle` that would remove the
  guesswork.

- **New selector: `--label`.** Framework-built controls carry no id of their own —
  a `Spinner` dropdown's rows and a `PopupMenu`'s items share one resource id
  (`text1`, `title`), and a `UIAlertAction` cannot take an identifier at all. They
  were captured but unaddressable, so flows resorted to scraping a `ref` out of a
  snapshot (refs are minted per capture, so that was fragile by construction).
  `--label` matches visible text or the a11y label: exact first, substring second,
  scoped to the topmost window, with nested duplicates collapsed to the innermost
  node (an alert button wrapping a same-text label is not an ambiguity). **A
  genuinely ambiguous label is an error, never a silent first match** — that
  silent collapse is how a tap lands on the wrong row while looking like it worked.
  Implemented on both hosts; the iOS e2e's alert step now uses it instead of the
  python ref hack.

- Sample app + e2e: a **popup windows** scenario (Android) covering the app-owned
  windows that are not dialogs — `PopupWindow`, a `Spinner` dropdown, and a
  `PopupMenu` — each attaching its own `WindowManagerGlobal` root through a
  different framework path. All three were already captured correctly; the e2e
  pins that, and pins that their rows are reachable only through `--label`.

- **Scroll evidence: `Node.scroll` / `CompactItem.scroll`.** A recycling or lazy
  container binds only its visible window, so a far-down row has no node, no
  frame, and no selector — it is ABSENT, not off-screen. Until now a
  `RecyclerView` / `LazyColumn` / `UIScrollView` looked like any other container,
  which made "selector not found" indistinguishable from "this app has no such
  element". Every scrollable container now reports whether it can still move in
  each direction (Android `View.canScrollVertically/Horizontally` restricted to
  `ViewGroup`s — a `TextView` with overflowing text answers `true` too and would
  bury the real container; Compose's semantics scroll-axis ranges, honouring
  `reverseScrolling`; iOS `UIScrollView` content offset vs content size), rendered
  in compact as `scroll:up,down`. Selector-miss diagnostics on BOTH hosts now name
  the scrollable containers on screen and say an unbound row has no node yet —
  stating the fact, never promising the element is down there.

- **New: `act scroll-to`.** `tap` alone cannot reach a row a recycling list has
  not bound, so "tap the 40th row" was unreachable and an agent scripting blind
  swipes had no termination condition. `act scroll-to --test-id X
  [--container <sel>] [--direction down|up|left|right] [--max-swipes N]` drags the
  scrollable container until the selector resolves to a point INSIDE it, then
  reports `swipes`, `direction`, `container`, and the usable point. This is not
  the `wait --for appears` primitive that was dropped on reliability grounds: that
  one's success test was `isVisible`, a weak platform-divergent proxy, while this
  one is `act tap`'s own resolution plus containment in the container's rect.
  Two details are the whole contract: it drags SLOWLY rather than flicking (a
  flinging list kept moving after the gesture returned — measured: the reported
  point was already stale by the next command), and once found it polls until the
  position stops changing and reports `settled`. Exhaustion is a loud failure that
  distinguishes "the container ran out of travel, nothing under that selector came
  into view" from "the swipe budget ran out". Both platforms: the Kotlin helper for
  Android, the Swift host (HID drags) for the iOS simulator. Two subtleties the
  first cut got wrong and now guards: the container is chosen only from the TOPMOST
  window (a background screen's page scroller can be larger than the foreground
  list, so plain "largest scrollable" moved something invisible), and the direction
  is locked for the run (re-picking per iteration made an absent selector ping-pong
  at the list's end instead of finishing a sweep).

- Sample: the home scenario list is now inside a `ScrollView`. It had outgrown one
  screen, so the last rows were clipped and genuinely untappable — a resolved tap
  landed on the system navigation bar and silently did nothing. The Android e2e's
  navigation helper now uses `act scroll-to` before tapping a row, dogfooding the
  primitive on the exact failure that surfaced this.

- Sample apps + e2e: a **long list** scenario on both platforms (60 rows;
  `RecyclerView` on Android, SwiftUI `List` on iOS) that pins the recycling
  boundary as an executable assertion: the first rows are bound, row 40 is not,
  the container reports `scroll:down`, and a miss on row 40 explains itself.

- iOS `--region` now also matches a region **source** (`--region touchDelegate`),
  matching the Android resolver — the two had drifted when source matching landed.

- **Compose text links are addressable.** A `Text` carries its `LinkAnnotation`s
  as `AnnotatedString` ranges, not as child nodes, and the region channels run on
  Views — so a two-link agreement row in Compose was captured as ONE node with no
  regions and no char grid, while the identical `ClickableSpan` row on a `View`
  decomposed fine (measured on API 36 / Compose 1.7.5). `ComposeTextRegions` now
  recovers them from the surface Compose exposes to accessibility: the semantics
  config's `Text` (`getLinkAnnotations` for the authored ranges) plus the
  `GetTextLayoutResult` action — the one TalkBack invokes — for the laid-out glyph
  geometry, which is the Compose analogue of `Layout`. Emits one `span` region per
  link with its own per-line rects and its url/tag as the target, plus a char grid
  so an arbitrary substring stays targetable. All reflective (the agent keeps its
  `compileOnly` Compose dependency) and fails closed to no regions on any shape
  mismatch. e2e asserts each link resolves to its OWN rect — tapping "Terms" must
  not open "Privacy".

- e2e: **same-origin iframe geometry** is now asserted on both platforms. The DOM
  walk already pierced same-origin frames and accumulated the frame's page offset
  (frame content coordinates are viewport-relative), but nothing checked the
  offset: Android asserted no iframe at all, and iOS only resolved the chained
  selector through DOM *activation*, which passes even when the rect is wrong.
  The frame's button now carries its own `onclick`, and both suites assert the
  inner rect sits inside the frame's rect and that a COORDINATE tap (adb / HID)
  at that rect fires it. Verified correct as shipped — this is a regression net,
  not a fix.

- Sample app + e2e: a **Compose semantics** scenario, the first end-to-end
  coverage of `ComposeSemanticsBridge` (it shipped with no scenario, so nothing
  proved the reflective SemanticsNode walk still worked against a current Compose
  runtime). It asserts a `Modifier.testTag` tap lands, `act type` reaches a
  composable `TextField`, a Compose `Dialog` is found as its own window with its
  own semantics owner, an `AndroidView` interop child is captured as a real View,
  and every tagged composable carries a usable frame. Adds Compose to
  `sample-app` (the repo's only Compose surface, existing for this purpose).

- **Fixed: two region channels that shipped but never worked.** Both were
  discovered by finally giving them a sample scenario (a self-drawn canvas
  control), and both failed silently — they returned zero regions rather than an
  error, so a self-drawn control looked simply "unaddressable".
  - `a11yVirtual` on Android probed virtual ids `0 until childCount`, but a
    provider's ids are chosen by the app: `ExploreByTouchHelper` may hand out
    dense indexes OR stable domain ids (a seat number, a row id). Controls using
    the latter recovered nothing. It now asks the host node for its declared
    child ids, then the androidx helper for `getVisibleVirtualViews` (app-side
    code, so no non-SDK restriction applies), and only then falls back to the
    dense probe.
  - `a11yVirtual` on iOS read only the `accessibilityElements` array, so every
    control implementing the other legal `UIAccessibilityContainer` convention —
    `accessibilityElementCount()` + `accessibilityElement(at:)`, elements built
    on demand — surfaced nothing. Both conventions are now read.
  - `touchDelegate` reflected `TouchDelegate.mBounds`, which the platform blocks
    (`api=max-target-o`) for any app targeting O or newer — i.e. the channel was
    dead on every modern app. It now reads the public
    `TouchDelegate.getTouchDelegateInfo()` (API 29+), and reports nothing below
    29 rather than guessing. The forwarded rect carries no label because a
    delegate's target resolves only through an accessibility connection, which an
    in-process agent has no access to; `act tap --region touchDelegate` addresses
    it by source name instead (`--region` now matches a region source, not just a
    label).

- Sample apps + e2e: a new **canvas control** scenario on both platforms — a
  control that paints its own segments (no child views), exposing them as virtual
  accessibility sub-nodes, plus (Android) a 20px icon whose hit area is expanded
  across the whole row by a `TouchDelegate`. Each platform ships one control per
  container convention, so a harness cannot pass by covering only one. Every
  assertion drives a tap from the recovered rect and checks the app's own status
  text: the controls hit-test privately and the delegate rect's center is nowhere
  near the icon, so a wrong rect silently does nothing.

- Lottie internal-element recognition. When an app bakes a whole dialog (title,
  message, buttons) into a single Lottie animation, the plain tree sees one
  opaque node and nothing downstream can act on it. A new **Lottie bridge**
  recovers those elements from the parsed composition Lottie already holds in
  memory: it enumerates the text layers, reads their strings, and maps each
  layer's transform through the composition→view scale to a screen rect —
  surfaced as `RegionSource.lottie` sub-regions so the existing region pipeline
  (`ui regions`, `act tap --region`, `--point`) can target them. Android
  (`LottieBridge.kt`) reflects `LottieComposition`; iOS (`LottieBridge.swift`)
  `Mirror`-reflects the model (walking the superclass chain for the inherited
  `transform`). Both are pure reflection — the agent never links Lottie — and
  fail closed to zero regions on any shape mismatch. Rects use the authored text
  box (`boxPosition`/`boxSize`, iOS `textFramePosition`/`textFrameSize`) plus
  measured glyph metrics, so a rect hugs its text and its center is a reliable
  tap point. e2e on both platforms asserts the elements are recovered and that a
  tap at a recovered position fires the app's in-canvas hit-test callback.

- Sample apps + e2e: three more dialog scenarios on both platforms — a **native
  Lottie dialog** (a dialog hosting a real Lottie view), a **web Lottie modal**
  (a `lottie-web` modal inside the WebView, bundled offline), and a
  **web-component dialog** (a custom element whose content lives in an open
  shadow root, folded in via shadow piercing). Adds the `lottie-android` /
  `lottie-ios` dependencies and a bundled Lottie asset + `lottie-web` runtime.

- Sample apps + e2e: a new **system dialog** scenario on both platforms exercises
  the multi-window / presented-content walk that no other scenario covered.
  Android's `SystemDialogScenarioActivity` raises an `AlertDialog` (a separate
  `WindowManagerGlobal` root); the e2e asserts the dialog's own content
  (`alertTitle` / `message` / `button1` / `button2`) is captured AND the
  background trigger is reported `occluded-by` the dialog window — the
  window-vs-window occlusion path. iOS's `SystemDialogViewController` presents a
  `UIAlertController` *inside* the presenting window (not a separate `UIWindow`),
  so the e2e asserts the alert's title / message / actions are captured but
  deliberately makes no `occluded-by` assertion — there is no second window there to
  occlude anything. (At the time this also reflected iOS capturing every `UIWindow`
  as `.view`; that has since been fixed — see the overlay-window entry above.) Both scenarios
  are app-owned dialogs — a true system-process permission prompt is out of reach
  for an in-process agent. Verified on an emulator + simulator; element content
  and frames confirmed pixel-accurate against screenshots.

- Network capture: a bridged engine start that the sync side abandons on timeout
  no longer leaks a bound port. `LoomCaptureLane.start()` and
  `startPhoneOnboarding()` bridge Loom's async engine to the daemon's synchronous
  lifecycle via a semaphore; on timeout they threw but left the `Task` running, so
  a start that completed *after* the timeout left an engine (or provisioning
  server) bound to a port with no owner to stop it. The bridging Task now claims
  its result under the lock and, when the sync side has already given up, stops the
  orphaned engine / provisioning server instead. (Cancelling the Task alone
  wouldn't help — Loom's actor calls don't observe cancellation, so an in-flight
  start still binds.)

- Android inject: the JDWP forward host port is now probed (`ServerSocket(0)`)
  instead of derived from the pid (`16000 + pid % 1000`). The derived port could
  collide with a stale forward left on it, an active runtime forward in the same
  range, or — for two pids congruent mod 1000 — a concurrent inject. A probed-free
  port can't already hold an adb forward (adb keeps forwarded ports bound), so all
  three modes are eliminated.

- iOS `act --verify` now works. The iOS path previously accepted `--verify` and
  silently dropped it, so an agent believed it had checked a post-condition it
  never checked. `IosHelperClient` now captures the watched node's state before the
  gesture, polls the snapshot after (up to `--verify-timeout`, default 2s), and
  emits the same `{selector, changed, note?, changes[]}` shape the host's
  `printVerify` renders — the iOS analogue of the Android helper's `HelperVerify`.
  The `--verify` token grammar (`#id`/`testId=`/`@id`/`resourceId=`/`css=`/`ref=`/
  bare ref/`true`) is shared-by-duplication with Android and now drift-guarded by
  `IosVerifyTokenTests`. Exercised end-to-end in `scripts/e2e-ios.sh` (login-status
  flip).

- RN `nativeID` selectors now resolve for `mutate` on Android. `SnapshotCapture`
  derived a node's `testId` as `testTag ?: nativeId ?: resourceId`, but
  `MutationEngine.findIn` only compared the keyless `testTag`, so a `testId` that
  came from an RN `nativeID` (a keyed tag) matched during capture but missed during
  device-side resolution — `mutate --test-id <nativeID>` silently found nothing.
  `findIn` now mirrors the capture derivation exactly.

- Network capture hardening (`LoomCaptureLane`): the capture lane no longer fails
  silently in ways that corrupt the evidence trail. (1) A transient
  `ruleStore.exportPackage()` error during a rule sync previously fell through to
  `setRules([])`, silently wiping every active rule in the engine — it now skips the
  sync and keeps the last-applied rules, logging a warning. (2) The rule-sync bridge
  gained the 30s timeout every other engine bridge already had, so a stalled engine
  can't deadlock the serial sync queue. (3) Body-store, CA-export, and `setRules`
  failures that were swallowed by `try?` now emit `warning: reticle capture: …` to
  stderr, so missing body/CA evidence is diagnosable instead of looking like a
  genuinely empty body or a misleading "file not found" downstream. (4) The
  `seen` flow-id set is now a bounded FIFO (cap 8192) instead of growing without
  limit over a long-lived daemon. (Session `network-bodies/` file count is still
  unbounded — it's coupled to event-ring eviction and left for a follow-up.)

- Network capture: **flow replay + diff** closes Loom's capture → modify → replay
  → diff loop. `POST /sessions/current/flows/{id}/replay` (CLI: `reticle replay
  flow <request-id>`) re-sends a captured flow through the engine's forwarder with
  optional overrides — `--method`/`--url`, `--set-headers`/`--remove-headers`, and
  `--body`/`--body-file`/`--clear-body` — then emits a `network.replay` event and
  returns the diff of the replayed response vs the original (status, body size, and
  header add/remove/change **by name only**, so a changed `Authorization` is named
  without logging the secret). The replayed flow's stream copy is suppressed in the
  capture lane so it shows once, as the replay event, with both bodies stored as
  artifacts. The payload schema gains optional `replayedFrom` + `diff` fields. Prior
  to this, Reticle captured and mocked but never exercised Loom's `replay` write
  action — the agent can now diff "same request without the auth header" as evidence.

- Network capture: the session mock store is now a general **traffic-rule**
  store, closing the gap where Reticle consumed only Loom's mock route while the
  engine's `RuleActions` offered far more. A rule's `actions` now carry one of
  four routes — `mock` (reply with a stored value, as before), `block` (fail the
  connection, for network-failure evidence), `mapRemote` (re-target the request
  at another origin, e.g. staging), or `passthrough` — plus orthogonal modifiers
  that compose with any route: `delayMs` (latency injection), request/response
  header rewrites, and request/response find/replace substitutions. These map
  1:1 onto Loom's `RuleActions` in `LoomCaptureLane.translate`. **Breaking
  (host-only surface; the agent never consumed it):** the `/sessions/current/mocks/*`
  routes are now `/sessions/current/rules/*` (values under `/rules/values`), the
  `reticle mock …` CLI is now `reticle rule …` with `--action`/`--map-to`/
  `--delay-ms`/`--set-*-headers`/`--remove-*-headers`/`--request-subs`/
  `--response-subs` flags, and session state persists to `rules.json` /
  `rule-values.json`. On captured evidence the `mocked`/`mockRuleId` payload
  fields are generalized to `ruleApplied`/`ruleId`/`ruleAction` (any route that
  acts is attributed, not just mock); `mockValueId` stays for the mock route. The
  Web panel's Mock filter/group/badge become the Rule filter/group/action badge,
  and "copy as mock" is now "copy as rule".

- Action traces: the on-disk `trace.json` manifest now carries a `platform`
  field ("android" / "ios") on both platforms. iOS already emitted it; the
  Android writer did not, so an Android trace was not self-describing and
  consumers could not tell the two apart from the manifest alone. The field is
  copied from the captured snapshot's platform and is optional/defaulted, so
  older manifests and direct callers stay wire-compatible.

- Tests: `scripts/e2e-android.sh` — an end-to-end smoke test for the Android
  agent, the analogue of `scripts/e2e-ios.sh` and the previously-missing
  coverage for the Android device-side runtime. It builds the agent + both
  sample flavors, installs them, and drives the full round trip against a
  device/emulator (linked launch, `ui report`/`compact`, selector tap with
  `--verify` + `--trace-output` + `replay gif`, ASCII/non-ASCII `type`,
  runtime `mutate`, agreement-region resolution, WebView DOM tap, the login
  keyboard-occlusion trap, `type --submit`, and the JDWP inject path on the
  `noagent` flavor) — every step asserting an observable side effect. It polls
  `status`/`compact` for readiness instead of fixed sleeps, so it rides out
  slow cold starts on a software-GPU emulator. Local/manual like the iOS e2e;
  not wired into CI (which has no attached device).

- One-shot commands now take a warm path by default: the first helper-backed
  command fork-execs a per-device `reticle helper-daemon` (a Unix-domain
  socket under `~/.reticle/helperd/`, carrying the helper's own JSONL
  envelope) and waits ≤5s for the socket; every later command reuses the
  resident helper over the socket instead of spawning a new helper process —
  measured ~20ms per command against ~90ms for a direct native-helper spawn,
  with the win growing on JVM helpers and multi-RPC commands. The daemon
  answers `helperd/info` / `helperd/shutdown` itself, restarts automatically
  when it is stale (CLI upgrade or helper rebuild, detected via version +
  helper mtime), exits after 600s idle (`RETICLE_HELPERD_IDLE` overrides),
  unlinks its socket on exit/SIGTERM, and exits when its helper child dies so
  the next command starts fresh. `--no-daemon` / `RETICLE_NO_DAEMON=1` opts
  out; any bring-up failure falls back to the direct per-command spawn, so the
  hot path is never a reliability regression. The `serve --helper-broker` +
  `--use-daemon` HTTP route is unchanged and takes precedence when requested.

- `act --verify` no longer false-negatives on `testId=`/`resourceId=` verify
  tokens. The token parser only understood the sigil spellings (`#testId`,
  `@resourceId`, `css=…`); anything else silently became a `ref` lookup that
  could never match, so `--verify 'testId=checkout.status'` reported
  "node not present after action" regardless of the actual UI — and the README
  and skill batch examples taught exactly that spelling. The parser now accepts
  `testId=`, `resourceId=`, and `ref=` alongside the sigils, and an
  *unrecognized* `key=` token fails loudly instead of degrading into a
  never-matching ref.

- iOS: `act type` with a targeting selector now taps that field first (then
  settles 200ms) before typing, matching Android — HID typing and clipboard
  paste both land in whatever holds focus, so `type --test-id foo` used to
  silently type into the wrong (or no) field unless the caller tapped first.
  The result reports `focusedVia`, and the action trace carries the focus
  point so replay evidence shows where the text went.

- Capture proxy: the upstream forwarder's total-transfer timeout is now
  `max(600s, configured upstream timeout)` instead of a hardcoded 600s that
  silently clamped any longer `--upstream-timeout`.

- Capture proxy: a request body is now capped at 64 MiB of in-memory buffering
  by default (`--proxy-max-request-body-mb` on `reticle serve`). The upstream
  forward needs the whole body in memory today, so an unbounded upload could
  balloon the daemon; past the cap the proxy emits a `network.error` event,
  answers `413`, and closes the connection. Applies to both the plaintext and
  MITM paths. This is a safety valve, not a tight bound — the default clears
  ordinary photo/video uploads.

- Swift host: the `network.*` payload, event-envelope, and snapshot schemas are
  now validated at the value level against `reticle-protocol/schema/*.json`,
  matching the Kotlin contract test. The Swift side previously compared only
  field-name sets, so a type / enum / nesting drift (e.g. a MetadataValue
  discriminator or a number-vs-integer slip) could pass unnoticed. A small
  test-only draft-2020-12 validator (no third-party dependency) now checks the
  Swift-emitted snapshot, the shared iOS golden fixture, and the network/event
  golden fixtures; its own self-tests prove it rejects the drift it guards
  against.

## 0.9.3 - 2026-07-22

- iOS real-device enablement (docs + tooling, no runtime behavior change):
  - **CocoaPods linked path.** Ship `reticle-swift/ReticleProtocol.podspec` and
    `reticle-agent/ios/ReticleKit.podspec` so a CocoaPods app (e.g. a KMP iOS
    app) can link the agent Debug-only and call `Reticle.start()` — the
    recommended way to drive a real device, alongside the existing SwiftPM path.
  - **Debug-build injection.** `scripts/inject-ios-device.sh` (+
    `scripts/macho_add_load.py`, lief-based) inject the agent into an
    already-built, dev-signed debug `.app` with no source change: build
    `ReticleInjection.framework` for device, embed it, add an `LC_LOAD_DYLIB`,
    re-sign framework + bundle with the app's own identity, reinstall, verify
    over the USB tunnel. Documents what does NOT work on-device
    (`DYLD_INSERT_LIBRARIES` is stripped by the launch path; lldb `dlopen` is
    blocked on iOS 26) and that production/App-Store apps cannot be injected at
    all. Prefer the linked path; injection is for debug builds you can't edit.
  - `docs/ios.md` and the plugin skill document both real-device routes.

## 0.9.2 - 2026-07-22

- `act type --submit` presses the keyboard's action key after the text lands,
  collapsing the OTP-style `type` → `hide-keyboard` → `tap submit` three-step
  into one command. On Android the agent performs the focused field's IME
  editor action in-process (`POST /editor-action` → `EditorActionResult`):
  `TextView.onEditorAction()` drives the app's `OnEditorActionListener` — the
  exact hook React Native's `onSubmitEditing` listens on — where a host-side
  `KEYCODE_ENTER` inserts a newline into multiline fields and is dropped by
  some IMEs; fields that never declared an action are treated as Done. Because
  a real IME dismisses itself after a terminal action, the agent reproduces
  that: Done/Go/Search/Send also hide the keyboard, Next/Previous keep it up.
  Falls back to `KEYCODE_ENTER` when the agent is unreachable. On the iOS
  simulator `--submit` sends a HID Return (the bridge already mapped `\n` to
  the Return usage). Works in `act batch` steps as `"submit": true`. Verified
  end-to-end on a real Android device (ColorOS, API 35) and an iOS 26.3
  simulator: one command types the code, fires the app's submit listener, and
  leaves the keyboard dismissed.

- Android: React Native's `nativeID` is now a first-class `testId` source.
  RN stores `nativeID` as a *keyed* view tag (`setTag(R.id.view_tag_native_id,
  …)`), invisible to the keyless `view.tag` read that fills `testId` — so an
  RN screen with `nativeID` props (and no resource-ids) was untargetable by
  `--test-id` and agents fell back to per-restart dynamic refs. The capture
  now resolves RN's tag id by name at runtime (no RN dependency) and fills
  `testId` from: Compose/classic testTag → RN `nativeID` → resource-id entry
  name. (RN's `testID` already worked — it writes the keyless tag.)

- `act --alias @N` now re-resolves the cached outline entry against the live
  tree before acting, instead of trusting the coordinates the outline cached.
  A keyboard appearing or a relayout between `ui outline` and `act` used to
  land the tap on stale coordinates *silently* — worse than a stale `ref`,
  which at least fails loudly. Matching is by the entry's stable selector
  (testId / resourceId / css) first, then label+role, preferring the node
  nearest the cached frame when several match (repeated list rows); the
  cached frame remains the fallback when the runtime is unreachable, and the
  result's `source` says which path ran (`outline:@N->live` vs
  `outline:@N (cached frame)`).

- Docs: the `act batch` examples now show what was always true — step keys
  are the protocol field names, so `resourceId`, `ref`, `point`, `alias`, and
  `region` all work in steps, not just `testId`/`css` (README, skill, and
  helper-rpc.md all updated; this cost a real user their whole steps.json
  workflow). `app inject` success output now points out that debug builds
  linking the agent AAR skip inject entirely, and the skill documents the
  `serve --helper-broker` daemon path and the alias live-re-resolve semantics.

- Sample apps (both platforms): the login scenario's code field now also
  submits on the keyboard's Done/Return key (the common OTP pattern), giving
  `act type --submit` a listener to land on. The bottom submit button stays —
  it is the occlusion scenario the hide-keyboard E2E drives.

## 0.9.1 - 2026-07-22

- Android: the system keyboard (IME) is now observable and dismissible. The
  IME is another process's window — it never appears in the captured node
  tree, so a login button it covered still read as `tappable` and agents
  tapped straight into the keys (a real stuck login flow: type the SMS code,
  keyboard stays up, submit button underneath it). Snapshots now carry
  `screen.keyboard` (`visible` + screen-coordinate `frame`), probed in-process
  from window insets (`WindowInsets.Type.ime()` on API 30+, visible-frame
  heuristic before that); the agent answers `GET /keyboard` and
  `POST /keyboard/hide` (InputMethodManager against every attached window
  token, then re-probe so the caller gets the settled state); and
  `reticle act hide-keyboard` drives it from the CLI, falling back to
  `KEYCODE_ESCAPE` when the agent is unreachable — unlike BACK, ESC doesn't
  navigate back when the keyboard is already gone. `act type` results now
  include `keyboardVisible` when the runtime is reachable.

- iOS: the same keyboard surface, implemented in-process in `ReticleKit`. A
  `KeyboardMonitor` caches the keyboard notification stream (the one exact
  public signal — the keyboard's own windows attach on first text focus and
  never detach, so window presence proves nothing) and falls back to scanning
  for a text-input first responder when injected mid-keyboard. `GET /keyboard`
  / `POST /keyboard/hide` (resignFirstResponder via the responder chain, then
  re-probe) mirror Android; `reticle --target ios act hide-keyboard` works on
  simulators and real devices alike since it needs no HID surface, and iOS
  `act type` also reports `keyboardVisible`. Verified end-to-end in
  `scripts/e2e-ios.sh` (see below). Simulator caveat baked into the script:
  with "Connect Hardware Keyboard" on, iOS never shows the software keyboard —
  the script now disables it up front.

- Sample apps (both platforms): a new "Login keyboard trap" scenario — code
  field on top, submit button pinned to the bottom, keyboard avoidance
  deliberately defeated (`adjustNothing` on Android, `.ignoresSafeArea(
  .keyboard)` on iOS) — reproducing the real stuck-login layout. The iOS e2e
  drives it end to end: type → `keyboardVisible=true` → compact marks
  `login.submitButton occluded-by:keyboard` → `act hide-keyboard` →
  `keyboard: hidden` → submit succeeds. The same flow was verified by hand on
  a real Android device (ColorOS, API 35) — including the probe fix it forced:
  IME insets only dispatch to the focused window, so the agent probes every
  attached window and lets any that sees the keyboard win.

- Compact view: items whose tap point something else sits on top of are marked
  `occluded-by:<what>` — generically, not keyboard-specifically: a higher
  z-order window (dialog/popup over a background page) marks the items it
  covers with its window ref, and the visible IME marks the items under it
  with `occluded-by:keyboard`. `ui compact` also leads with a
  `keyboard: visible/hidden` header line (with a dismiss hint) whenever the
  platform probed the IME. Protocol: `ScreenInfo.keyboard` (`KeyboardInfo`)
  and `CompactItem.occludedBy` added to the schema, the Kotlin model, and the
  Swift `ReticleProtocol` mirror — all optional, wire-compatible both ways.

## 0.9.0 - 2026-07-21

- iOS: fixed in-process screenshots going permanently black after the first
  keyboard appearance. `ScreenshotCapture` composited every attached window
  into one opaque context; the keyboard's system window (`UITextEffectsWindow`)
  attaches to the scene on first text focus, never detaches, and its content is
  not renderable in-process — `drawHierarchy` black-filled the full-screen rect
  over the app content on every subsequent capture. Each window now renders
  into its own transparent layer and only layers whose `drawHierarchy` reports
  success are composited, so an unrenderable system window is skipped honestly
  instead of covering the app. Found by replaying a recorded flow that types
  into a text field — every frame after the keyboard step was black.

- Host: new `reticle replay gif <trace-dir>` — the first evidence-workflow
  product (A4 on the roadmap). It stitches the action-trace packages a flow
  recorded with `act … --trace-output` into a device-framed animated GIF:
  each step contributes its before-screenshot (with the gesture drawn where the
  input landed — a ring at the resolved tap point, an arrow for a swipe/drag
  stroke) and its after-screenshot (captioned with the diff change count), with
  step captions built from the trace's gesture + selector. Works on Android and
  iOS traces alike (one manifest reader covers both), is host-local (reads
  evidence already on disk, never touches a device), and renders with
  ImageIO/CoreGraphics only — no new dependencies. Marker geometry is scaled
  through the snapshot's `screen.size.width`, not the screenshot's pixel width
  — on iOS the gesture coordinates are points while the screenshot is device
  pixels (caught by replaying a real simulator trace; a pixel-space mapping
  drew the tap ring at ⅓ of the true position), while on Android the two
  spaces coincide and nothing changes. Steps without screenshots
  are skipped with a stderr note, never fabricated. Options: `--output`
  (default `<trace-dir>/replay.gif`), `--width`, `--frame-ms`. Covered by unit
  tests over synthetic traces and a step in `scripts/e2e-ios.sh` that replays
  the real recorded checkout tap.

- Host: the network capture lane — proxy, MITM, certificate store, body store,
  and `NetworkMockStore` — is now its own `ReticleNetworkLane` SwiftPM target
  instead of living mixed into `ReticleHostCore`. It depends only on a new
  dependency-free `ReticleHostShared` layer (`JSONValue` / event models /
  `HelperError`) plus SwiftNIO, and reaches the session store through a single
  `NetworkEventSink` protocol (`emit` + `sessionDirectory`) rather than
  referencing `EventStore` directly — the compiler-enforced realization of the
  "proxy backend behind an interface" roadmap goal, so the lane builds and tests
  without the daemon and swapping the engine later means editing one target.
  `ReticleHostCore` `@_exported`s the two lower targets, so it is an internal
  boundary with no change to the public API or the CLI. No behavior change.
- Host: new `scripts/e2e-proxy.sh` end-to-end smoke test (host-only, no device)
  covering the whole network lane over real sockets — `reticle serve` with the
  proxy, mock rules set through the `reticle mock` CLI, a plaintext mock hit, an
  HTTPS mock hit decrypted through MITM (verified against the generated CA), a
  real upstream forward, a 502 fall-through after `mock clear`, and the
  `network.*` evidence trail in `events.jsonl`. Runs in CI on the release binary.

- iOS: the SwiftUI accessibility bridge now descends into **unlabeled AX
  container elements** instead of filtering them out. Some hosting surfaces
  (notably a `TabView` page host — `TabHostingController`'s hosting view) wrap
  the whole page's elements in one container with no label, no identifier, and
  `isAccessibilityElement == false`; the previous one-level read dropped it —
  and with it the entire page — so tab-page content was plainly visible on
  screen yet absent from every snapshot, and `--test-id` selectors inside a tab
  could never resolve. A `NavigationView`'s `_UIHostingView` returns its
  elements flat, which is why every existing scenario worked and the gap went
  unnoticed. The walk is depth-capped and cycle-guarded. Found via a new
  four-item TabView scenario in `sample-app-ios` ("Tab bar"), which is now part
  of `scripts/e2e-ios.sh`: it asserts the four `UITabBar` items, that the
  SwiftUI page folds in as axElements, and that a HID tap on the Orders item
  flips `tabbar.status` to "Selected: orders". Also observed there (not a
  Reticle bug, worth knowing): the iOS 26 Liquid Glass `UITabBar` renders two
  stacked button layers, so each tab item appears twice at the same frame.

## 0.8.0 - 2026-07-20

- iOS: the capture proxy now supports **real devices**, not just simulators. A
  new `--proxy-bind` option (default `127.0.0.1`) lets the proxy bind the LAN
  (`0.0.0.0`) so a phone on the same Wi-Fi can reach it — previously the proxy
  was hardcoded to loopback, unreachable from a device. `serve --target ios
  --proxy-device` now prints device-appropriate routing: for a LAN bind it gives
  the Mac's LAN IP + port for the phone's Wi-Fi proxy and the CA-as-profile
  install/trust steps (`--proxy-install-ca` stays simulator-only — a device
  trusts the CA manually as a profile). Verified end-to-end on an iPhone 13 Pro
  Max / iOS 26: a Safari `https://example.com` fetch surfaced a decrypted
  `GET … 200` event targeted `ios:<ecid>`. Binding non-loopback is an explicit
  opt-in (it exposes the MITM proxy on the LAN for the run).

- iOS: the agent now engages the accessibility runtime at startup
  (`_AXSSetAutomationEnabled(true)` from `libAccessibility` — the flag XCUITest
  sets, no VoiceOver, fires no control), so SwiftUI `axElement`s carrying
  `.accessibilityIdentifier` surface on the **first** observation on a real
  device. Previously they built lazily and only after an accessibility action,
  so selector targeting silently missed on first use (the device e2e worked
  around it with a throwaway activation; that warm-up is now just a defensive
  poll). Verified on iPhone 13 Pro Max / iOS 26: the first `ui report` after
  launch lists all SwiftUI scenario buttons. (An earlier attempt used the
  non-existent `_AXSSetApplicationAccessibilityEnabled` setter symbol, hence the
  prior "flag insufficient" note — the working symbol is the automation pair.)

- iOS: hardened `scripts/e2e-ios-device.sh` and validated the full linked-agent
  real-device path on an iPhone 13 Pro Max (iOS 26): `status / ui report /
  ui compact / ui screenshot / act activate / mutate / debug logs` and the
  action-trace evidence package all confirmed over the USB tunnel. Script fixes
  surfaced by the run: auto-resolve the device via `idevice_id -l` (the hardware
  ECID is the one id that works for `xcodebuild -destination`, `devicectl`, and
  `iproxy` — the `devicectl` coredevice UUID does not); a lock-state precheck
  (a locked device rejects launch and suspends the app); wait for the agent to
  become reachable; and an action-trace assertion. Documented a real-device
  behavior: SwiftUI `axElement`s materialize only after an accessibility *action*
  (plain observation does not engage the tree), so the script does a throwaway
  activation to warm it before selector steps. Agent-side auto-engagement remains
  a follow-up (the `_AXSSetApplicationAccessibilityEnabled` flag alone did not
  suffice).

- iOS: `reticle serve --target ios` extends the host-side capture proxy
  (`network.*` events, HTTPS MITM, session mocks) to iOS simulators, within the
  same no-hook boundary as Android. Two host actions replace `adb`: the MITM CA
  is trusted in the booted simulator via `xcrun simctl keychain add-root-cert`
  (automatic with `--proxy-install-ca`, simulator-scoped), and — because a
  simulator/real device has no per-app proxy hook and rides the host network —
  proxy routing is **printed, not auto-applied**: `serve` emits the exact
  `networksetup` set/restore commands for the active service so the user runs and
  reverts the host-wide proxy explicitly (no risk of a killed daemon stranding
  the Mac on a dead port). Captured traffic is attributed `ios:<udid>` (the proxy
  target label is no longer hardcoded `android:`). Verified on iOS 26.3: a Safari
  `https://example.com` fetch surfaced a decrypted `GET … 200` event targeted
  `ios:<udid>`. This closes the iOS gap in the network-evidence lane and unblocks
  the security B-lane (B1/B2) on iOS.

- iOS: `act` (tap/swipe/drag/type/activate) now emits **action-trace evidence
  packages** — the iOS analogue of Android's traces, so an iOS action feeds the
  `reticle serve` timeline and web panel identically. `--trace-output <dir>` (or
  an active daemon session, which auto-traces) writes before/after snapshots +
  screenshots + a `trace.json` manifest whose compact diff records the observable
  change (e.g. `checkout.status: "Cart: 3 items" → "Paid!"` — honest proof the
  action landed). The manifest carries `platform: "ios"`, and the daemon now
  labels ingested traces `ios:<pkg>` (previously hardcoded `android:`). The diff
  is a field-for-field Swift port of `reticle-core`'s `ActionTraceDiff`, and
  `e2e-ios.sh` asserts the trace package and its diff. This closes the iOS gap in
  the evidence pipeline: iOS could drive actions but produced no evidence.

- iOS: fixed HID input (`act tap`/`swipe`/`drag`/`type`) silently doing nothing
  on the simulator. The previous path built the event from
  `IndigoHIDMessageForMouseNSEvent` and delivered it over a raw `SimDeviceIO`
  mach send right; on iOS 26.2/26.3 that *sends* cleanly but the synthesized
  touch never reaches native UIKit/SwiftUI controls (the worst failure — the
  agent believes it tapped). `CReticleSimHID` now builds a real `IOHIDEvent`
  digitizer parent + finger child, wraps it through
  `IndigoHIDMessageForTrackpadEventFromHIDEventRef`, patches the touch-target
  tag, and delivers via `SimDeviceLegacyHIDClient`
  (`-sendWithMessage:freeWhenDone:…`); keyboard uses
  `IndigoHIDMessageForHIDArbitrary`. Verified to land on native controls on iOS
  26.2 and 26.3. This also corrects the mistaken "HID needs iOS 26.3+" gate: HID
  is a capability, not a version cutoff — the host now guards on a capability
  probe (fails loudly only when the private SimulatorKit path can't initialize)
  and `e2e-ios.sh` runs HID steps on every runtime, asserting the tap actually
  lands (`checkout.status → "Paid!"`) rather than merely not erroring.

- iOS: web evidence hooks. The agent injects Playwright-style passthrough
  wrappers (console.*, window error / unhandledrejection, fetch / XHR timing)
  into every observed WKWebView; events buffer in an in-page ring (cap 200,
  drop-counted) and are drained into the agent log ring on every observation
  (`/report`, `/snapshot`, `/logs`), surfacing as `web_console` / `web_error` /
  `web_network` entries with structured metadata (url, method, status,
  durationMs). Pull-based like every Reticle observation: collection starts at
  the FIRST observation of a page; a document-start WKUserScript re-installs
  the hooks for later navigations. The sample fixture gained an evidence
  button and the e2e asserts console + fetch events end-to-end. Android port
  of the same script is a follow-up.

- WebView DOM walk (both platforms, shared script) now pierces **open shadow
  roots** and **same-origin iframes**, Playwright-style: pierced elements fold
  in as regular domNodes carrying a chained selector
  (`#shadow-host >>> #shadow-button`), with iframe content coordinates offset
  into page space. Cross-origin frames stay opaque. The sample's complex web
  fixture moved its shadow/iframe section above the fold so the e2e assertion
  doesn't sit on the viewport boundary.
- iOS: `act activate --css <chain>` performs in-process DOM activation — the
  agent resolves the selector chain in the live document (through shadow roots
  and same-origin iframes), runs a Playwright-style actionability check
  (attached / visible / enabled / receives pointer events, with honest failure
  reasons like `disabled` or `no_match`), and dispatches the full
  `pointerdown → mousedown → pointerup → mouseup → click` sequence. Needs no
  HID surface: this is the web tap path for real devices and for simulator
  runtimes with broken HID recognition. e2e asserts shadow/iframe chain
  activation plus an observable onclick side effect.

- iOS: multi-region decomposition reached parity with Android for UIKit text.
  The agent's new `RegionProbe` emits `span` regions from `.link` attribute runs
  (exact TextKit rects; UITextView lends its own stack, UILabel gets a rebuilt
  one), `a11yVirtual` regions from any view's child `accessibilityElements`
  (whole-view proxy elements filtered out), `colorSpan` regions for
  minority-colored runs, script-agnostic `textMarker` regions plus the
  `suspectedMultiRegion` flag for self-drawn bracketed/markdown rows, and a
  per-character `charGrid` for every UILabel/UITextView — so
  `act tap --region "Privacy"` resolves a phrase-level point on iOS (region rect
  first, char-grid substring fallback), same semantics as Android.
- iOS: `act activate` can now target SwiftUI content. axElement nodes resolve to
  their live accessibility element and fire `accessibilityActivate()` (e.g. a
  `NavigationLink` row navigates), `--region` narrows activation to an
  `a11yVirtual` sub-element, and text-range regions report an honest
  `no in-process activation surface` instead of tapping the whole view. Fixed
  SwiftUI `accessibilityIdentifier` being dropped for elements that respond to
  the selector without declaring `UIAccessibilityIdentification` (List rows),
  which made `--test-id scenario.*` unresolvable.
- iOS sample: restructured into the Android sample's scenario shape — a home
  list (Checkout / Agreement regions / SwiftUI boundary) with UIKit scenario
  screens mirroring the Android agreement cases (UITextView `.link` row,
  self-drawn bracketed-links label, plain-phrase label with non-default
  metrics, colorSpan row), plus a `RETICLE_SAMPLE_SCENARIO` launch-env hook so
  e2e runs can open a scenario without synthesizing navigation input.
- iOS: ported the read-only WebView DOM bridge to WKWebView. The view walk
  records web views on the main thread; the server thread then runs the shared
  DOM script (same payload as Android's `WebViewDomScript`) through
  `evaluateJavaScript` (750 ms timeout) and folds visible elements in as
  `domNode` children with `data-testid` selectors, `domCssSelector`, computed
  styles, and image metadata. `--css` selector resolution was added to the
  shared Swift `Render.findNode` (exact `domCssSelector` match, mirroring the
  Kotlin helper), so `ui node --css` and `act tap --css` now work on iOS. The
  sample gained the Android WebView scenario (same complex fixture) and the
  e2e asserts folded domNodes + CSS resolution.
- iOS: documented (docs/ios.md) that simulator HID taps do not trigger native
  UIKit/SwiftUI controls on the iOS 26.2 runtime (also reproduced with an
  independent implementation; the same tap DOES fire onclick inside WKWebView
  content, so delivery works and native gesture recognition is what rejects
  it); scripted flows should navigate via `act activate`. `scripts/e2e-ios.sh`
  now does, and asserts the agreement scenario's span/textMarker/colorSpan
  regions end-to-end.

- Proxy now **streams** upstream responses back to the client chunk-by-chunk
  instead of buffering the whole body first: identity bodies are forwarded under
  their original `Content-Length`, decoded/unknown-length bodies under
  `Transfer-Encoding: chunked`. A slow client back-pressures the upstream fetch
  (the transfer suspends until the client drains), and the stored response
  artifact is capped at the body limit while the full body still reaches the app
  (`responseBodyBytes` reports the true size, `responseBodyTruncated` flags the
  cap). Shared by the plaintext and HTTPS-MITM paths.
- Added a typed schema for proxy `network.*` payloads
  (`reticle-protocol/schema/network-event-payload.schema.json`) plus
  request/response/error golden fixtures. A Kotlin contract test validates the
  fixtures against it, and a Swift test pins the host emitter's field set to the
  same schema so the two ends can't drift.
- Network mock matching gained `match=regex` (validated at upsert, matched
  against both the request path and full URL), a `method=ANY` wildcard, and a
  query `"*"` presence predicate (key must exist with any value).
- Web panel: network cards can now be filtered by status class (2xx/3xx/4xx/5xx)
  and a free-text search over method/url/host/path/status/mock ids, composable
  with the existing mode filters; a new **Mock groups** view groups mocked
  requests under their rule (with hit counts) and the rest by host; and each card
  has a **copy as mock** chip that copies a ready-to-run `reticle mock set`
  command (including `--body-file` for the captured response). The panel stays
  display-only.

## 0.7.0 - 2026-07-14

- `act type` now focuses the target field first: given a targeting selector
  (`--test-id`, `--css`, `--point`, …) it taps the resolved field and waits a
  short settle before dispatching text, so input lands in that field instead of
  whatever happened to hold focus. Text is still inserted at the cursor.
- Added `Reticle.registerProbe(testId, metadata)`: a linked app can register a
  synthetic, addressable probe node for a spot with no convenient concrete view
  (canvas region, off-screen state).
- Added `schemaVersion` to the event envelope (currently `1`, required by the
  schema); legacy persisted session lines without it decode as version 1.
- Fixed `debug logcat` missing agent lines on busy devices: the tail cap was
  applied to the raw buffer before the tag filter, so Reticle lines could fall
  outside it and a linked agent looked unlinked. The dump is now tag-filtered
  first and bounded in code.
- Fixed mutation selector resolution and agent screenshots to consider all
  visible window roots topmost-first, so dialogs/overlays resolve and render
  correctly instead of the base activity winning.
- Hardened the agent's loopback HTTP server: route handler errors return a 500
  instead of dropping the connection; request bodies are capped at 4 MiB (413),
  header lines at 16 KiB, and a negative Content-Length is rejected (400).
- Hardened the helper RPC loop against type-mismatched request fields (a
  non-integer `id`, non-string `method`, or non-object `params` now yields a
  structured error instead of crashing the loop).
- Proxy correctness: a failed CONNECT now closes the client channel instead of
  leaking it, and `network.error` events preserve the real request method.
- Host resilience: SIGPIPE is ignored (a dead helper no longer kills the CLI),
  helper writes surface errors instead of trapping, and the final unterminated
  helper output line is read at EOF.
- Event store: id allocation and buffer mutation are serialized independently
  of file writes, and recovery sorts persisted events by id.
- Agent capture efficiency: AccessibilityNodeInfo instances are recycled and
  reflection lookups in the region/Compose probes go through a method cache.
- `adb` byte commands (screencap) return empty on a non-zero exit instead of
  passing through a truncated PNG.
- Raised host server bind-wait timeouts from 5s to 30s for slow CI machines.
- CI: Swift host tests now gate merges and releases (serialized suites to avoid
  a cross-suite server-start deadlock on core-scarce runners, with retries),
  SwiftPM dependency caching, a native-image serialization smoke test, and the
  release workflow runs the full test gates before publishing artifacts. Added
  a MITM/CONNECT proxy test suite.
- Slimmed the wire payload: `ReticleJson` now omits null and default-valued
  fields (`encodeDefaults=false`, `explicitNulls=false`, schema-required
  defaults pinned with `@EncodeDefault(ALWAYS)`), the agent serves HTTP
  responses with the compact (non-pretty) instance, and the `MetadataValue`
  `_type` discriminator uses short tags (`text`/`bool`/`int`/`real`) instead of
  fully-qualified Kotlin class names. Lossless; ~60% smaller snapshot responses.
- Fixed `SemanticTree.build` producing a dangling root and child refs: the tree
  now synthesizes a resolvable root, reparents kept nodes across dropped
  containers, and guarantees every node is reachable from the root.
- Unified the "targeting signal" test behind `Node.hasTargetingSignal()` so the
  semantic tree and compact observation can no longer disagree about which nodes
  are targetable.
- Hardened `input text` shell quoting to single-quote wrapping so typed text
  can no longer be interpreted by the device shell (`$(…)`, backticks).
- Made the daemon event store tolerate a corrupt or partially-written trailing
  JSONL line instead of failing to load the whole session.

Validation:

- reticle-core, Android helper, and Swift host tests.
- Plugin manifest/version-lockstep validation.
- GitHub CI for all pull requests.
- Real-device end-to-end pass on freshly installed builds: capture, tap/type
  (ASCII + CJK), mutate, screenshot, logcat, JDWP inject into the agent-free
  flavor, `serve` health, real-network proxy capture, and envelope
  `schemaVersion` — all verified on a physical device.

## 0.6.5 - 2026-07-03

- Added structured JSON result envelopes for host commands, including `--json`
  output on supported user-facing commands.
- Added selector-miss diagnostics with same-kind candidates from the current
  snapshot.
- Added `reticle ui outline`, short-lived `@N` aliases, and `reticle act
  --alias` for faster agent-driven targeting.
- Added a `reticle serve` helper broker so commands can reuse the daemon-hosted
  helper through `--use-daemon` or `RETICLE_USE_DAEMON=1`.
- Added runtime process advisories, persisted process-state, and matching
  serve-panel cues.
- Added repeated-item ordinal hints to UI outlines and alias cache entries.
- Added `reticle act batch` for ordered action sequences from a JSON file.

Validation:

- Swift host tests.
- Android helper tests.
- Plugin manifest/version-lockstep validation.
- GitHub CI for all optimization pull requests.
