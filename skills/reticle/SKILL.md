---
name: reticle
description: >-
  Inspect and drive a RUNNING Android app from its live runtime, not its source
  or a screenshot. Use when the task involves an Android app on a connected
  device/emulator and you need to: read the on-screen view / semantic /
  Jetpack Compose semantics tree or embedded WebView DOM, find a stable selector
  or exact tap coordinates, tap/swipe/type real input, target a specific phrase
  or link inside a multi-region control (e.g. an agreement row), inspect DOM CSS
  styles or image resources, read back what a recorded run did (`trace log`),
  show a read-only local Web panel for a multi-action evidence timeline, read app
  runtime logs, or live-patch a UI property (text/color/size/visibility) without
  rebuilding.
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

The CLI is on PATH as `reticle` while this plugin is enabled.

## Install (how the `reticle` binary is obtained)

`reticle` is the **Swift host** — a no-JDK native macOS 14+ arm64 binary that drives
Android through a sibling native helper (`reticle-helper`). **macOS 14+ arm64 only.**
The launcher (`bin/reticle`) resolves it in this order, first hit wins:
1. `$RETICLE_HOST` — explicit path to a `reticle-host` binary.
2. `$RETICLE_HOME/bin` — an unpacked release (`reticle-host` + `reticle-helper`).
3. `RETICLE_FROM_SOURCE=1` — **opt-in** source build (Swift host + native helper;
   needs the Swift toolchain + a GraalVM with native-image). Development only.
4. A **prebuilt release** — cached under `~/.reticle/cli`, else downloaded
   (SHA256-verified) from GitHub Releases. **This is the default** (needs
   `curl`+`unzip` and network; **no JDK**).

By default the prebuilt release is always used — there is **no silent source
build**. If it can't be obtained the launcher stops with actionable guidance.
`reticle version` confirms it's ready.

## Prerequisites (check, don't assume)

- The CLI is installed/buildable: `reticle version` (any output means it's ready).
- A booted device/emulator in the **`device`** state: `reticle doctor`. It now
  flags `offline`/`unauthorized` devices explicitly — those can't be driven until
  fixed (re-plug USB / accept the on-device debugging prompt).
- **One** target device. With several attached (e.g. a phone + a stray emulator),
  every driving command fails fast listing the candidates — scope it with a global
  `--serial <id>` (or export `ANDROID_SERIAL`, which Reticle also honors). `doctor`
  always lists them all regardless.
- `ANDROID_HOME` set, or adb on PATH.
- The target app must expose the Reticle in-process server. Three cases:
  - **Linked app** (you control the build): add the `reticle-agent` AAR — a
    no-op ContentProvider auto-starts the server, no code changes.
  - **Debuggable app without the AAR**: run `reticle app inject --package <pkg>`
    (the app must already be **running**). It loads a payload dex into the live
    process over JDWP and starts the same runtime — **no repackage, no root**,
    works even on locked `user` builds where `wrap.sh` is blocked. After it, every
    other command works unchanged. The target must already hold the `INTERNET`
    permission (real apps do); non-debuggable release builds still need Frida/root.
    Two things it needs from you, both about the main thread: the app must be
    **foregrounded** (injection runs on the app's own looper — a backgrounded app
    fails with exactly that message), and you must **not** nudge it with input in
    a loop while it runs. Reticle sends its own nudge; an extra queued touch stays
    unconsumed for the whole JDWP suspension and trips Android's 5s input-dispatch
    ANR, which kills the app mid-injection. When that happens the failure now says
    so — an ANR verdict with the system's own exit record, not a bare
    `EOFException`. `--restart-under-debugger` prevents it (it marks the app as
    being debugged, so AMS relaxes the verdict) but is **opt-in for a reason**:
    setting the debug app force-stops the target, so the app is relaunched and
    whatever screen it was on is gone. Reach for it after an ANR verdict, not
    before.
  - **Truly unreachable** (non-debuggable, no AAR): without an injection path
    `reticle ui report` cannot reach the app — say so rather than inventing data
    (use `reticle debug logcat` to confirm no agent, and `reticle ui screenshot`
    to still see the screen). The bundled `sample-app` links the agent (the
    `noagent` flavor is the test target for `app inject`).

On **iOS** (`--target ios`) the same "get the agent in" story has an analogue —
see `docs/ios.md`:
  - **Simulator**: `reticle --target ios app inject` (DYLD) or a linked build.
  - **Real device, linked (recommended)**: link the `ReticleKit` product
    (SwiftPM, or the shipped CocoaPods podspecs for KMP/CocoaPods apps) and call
    `Reticle.start()` at launch; drive over `iproxy -u <ecid> <port> <port>`.
    `scripts/e2e-ios-device.sh` runs the full round trip.
  - **Real device, injection (no source change)**: only for a **debug build you
    sign** (production/App-Store apps cannot be injected — Apple's security
    model). `scripts/inject-ios-device.sh <identity> <bundle> <app>` rewrites the
    binary with an `LC_LOAD_DYLIB` and re-signs; `DYLD_INSERT_LIBRARIES` and lldb
    `dlopen` do **not** work on-device. Prefer the linked path.

## Ports are per-app (no more 8765 collisions)

Device loopback ports are **process-global**, so if every linked app bound one
fixed port only the first to start would win and a host `adb forward` could land
on the *wrong* app. Reticle derives each app's port from its `applicationId`
(stable FNV-1a hash into `8765..9764`); the agent binds it and the CLI computes
the same value from `--package`, so no two apps collide and no discovery
round-trip is needed. Override with `RETICLE_PORT` in the app + `--port` on the
CLI. You normally never pass `--port`.

## Health & conflict checks (run when something looks wrong)

Before any snapshot/act/mutate Reticle does a fast (~2s) classified probe of
`/runtime` and fails with a precise message instead of hanging ~15s on a socket
timeout. Use `status` to inspect the live state:

```bash
reticle status                       # device readiness + what the registry knows
reticle status --package <pkg>       # full probe: app running? port? runtime health + identity
reticle debug logcat                 # the agent's OWN startup lines (works even when HTTP is dead)
```

`status` reports one of: **HEALTHY** (and whether the identity matches the
requested package — a mismatch is a port **CONFLICT** with another linked app),
**UNREACHABLE** (connection refused — app not running or agent not linked; status
cross-checks `debug logcat` to tell *not-linked* from *bound-port-failed*),
**UNRESPONSIVE** (connected but no response — stale socket / hung server; fix
with `adb shell am force-stop <pkg>` then relaunch), or **FOREIGN** (some other
server on the port — pick a different `--port`).

`status --package <pkg>` also compares the current app PID/runtime with the last
Reticle observation for that `serial + package`. If it prints `advisory:`, treat
the previous snapshot/alias/trace context as stale: the app may have restarted,
stopped, or lost its healthy runtime. JSON output carries the same object under
`data.advisory`; when `serve` is running the warning is also published as a
`runtime.advisory` session event.

`doctor`/commands also pre-check device readiness: an `offline` device triggers a
bounded `adb reconnect`, and `unauthorized`/`offline` produce an actionable error
instead of a 30s hang.

## Screenshots without the agent

`reticle ui screenshot [--package <pkg>] [--output shot.png]` uses the agent's
`/screenshot` when the runtime is reachable, and otherwise falls back to
`adb exec-out screencap`. This is the honest degraded mode for apps that don't
link the agent: you can still see the screen (and drive it via `adb`-backed
`act`/`--point`) even when no structured tree is available.

**Do not read a blank rect as "nothing was drawn."** The two capture paths are blind
in complementary ways, and each says so: the in-process picture omits a
`SurfaceView`'s content (its node is marked `pixels:unavailable`; on iOS the same
mark lands on the keyboard's host window), while a device-level `screencap` of a
`FLAG_SECURE` window comes back fully blank (that window is marked
`screencap:blank`). `ui screenshot` prints a `degraded:` line for whatever the
picture it just wrote is missing — when you see one, switch paths rather than
concluding the screen is empty.

## Core workflow

```bash
reticle doctor                                   # verify adb + devices (flags offline/unauthorized)
reticle app launch  --package <pkg>              # launch + adb forward + wait for runtime (LINKED apps)
reticle app inject  --package <pkg>              # debuggable app w/o the AAR: load+start the runtime over JDWP
reticle status      --package <pkg>              # probe runtime health + identity if anything's off
reticle ui report   --package <pkg> --output reticle-report
reticle ui compact  reticle-report/snapshot.json # token-cheap, one line per interactive/labelled node
reticle ui outline  --live --package <pkg>       # numbered agent-facing outline + @N alias cache
reticle ui node     reticle-report/snapshot.json --test-id <id>   # full node
reticle ui node     reticle-report/snapshot.json --css '#pay'      # WebView DOM node
reticle ui tree     reticle-report/snapshot.json --semantics  # semantic tree
reticle ui style    reticle-report/snapshot.json # geometry + style per node, in px/dp/sp, with provenance
```

Use `--json` when another tool or script will parse the result. Helper-backed
commands return one envelope shape: `{ "ok": true, "data": ... }` on success and
`{ "ok": false, "error": ... }` on failure. Keep text output for human-readable
interactive sessions.

Repeated command loops are fast by default: the first helper-backed command
starts a small per-device resident daemon (Unix socket under
`~/.reticle/helperd/`) and later commands reuse its warm helper automatically —
nothing to start or clean up (it exits after 600s idle). `--no-daemon` /
`RETICLE_NO_DAEMON=1` opts out; bring-up failures fall back to a direct spawn
on their own, so never treat the daemon as a precondition.

When a `reticle serve` session is already running you can instead route
commands through its helper broker explicitly:

```bash
reticle serve --session <name> --helper-broker
RETICLE_USE_DAEMON=1 reticle status --package <pkg>
reticle act tap --use-daemon --package <pkg> --test-id checkout.payButton
```

`--use-daemon` requires a live daemon started with `--helper-broker`.

When `serve` is running, open `/panel` to review action traces, network traffic,
and runtime advisories in one timeline. Action cards include copyable selector
and target chips; prefer those chips for quick follow-up commands, but refresh
with `ui outline --live` after navigation or a runtime advisory.

Send the **compact** observation to reason about the screen; query specific refs
with `ui node` only when you need full properties. Keep the full snapshot on
disk.

`compact` **folds anonymous layers into the node they wrap**. Toolkits build one
on-screen row out of several views and only one of them is nameable — an iOS
`UIPickerView` row is a cell, a label, and the cell's content view, three lines
with one meaning. A layer folds only when it has no id/label/text/region/scroll/
wheel of its own, a named node's tap point falls inside it, it *hugs* that node
(at least as large, at most 2×), and the two are related; the survivor inherits
`tappable`, so a folded row never reads inert. When anything folded, the last line
says how many. Nothing leaves the snapshot: every folded node keeps its ref and
properties, reachable with `ui node --ref rN` and visible in `ui tree`.

`ui outline --live --package <pkg>` is the fastest ad-hoc agent loop: it prints
visible labelled/interactive nodes as `@1`, `@2`, ... and writes a short-lived
alias cache for that package. Repeated vertical controls are annotated as
`item i/n` so list rows can be compared without opening the full snapshot.
`act --alias @N` re-resolves the cached entry against the **live** tree before
acting (matched by the entry's selector, then label+role; nearest to the cached
frame on ties), so a keyboard appearing or a relayout between outline and act
does not land the tap on stale coordinates — the cached frame is only used when
the runtime is unreachable, and `source` in the result tells you which path ran
(`outline:@N->live` vs `outline:@N (cached frame)`). Still re-run outline after
navigation or modal changes: `@N` numbering describes the outlined screen, not
the new one. The `item i/n` text is a hint, not a selector. Stable automation
should still prefer `--test-id`, `--resource-id`, `--css`, or `--ref`.

**Stacked screens: `--window top`.** A capture holds EVERY live window of the
process, and on Android a screen pushed over a still-alive one is the common case.
Flattened by geometry the two interleave: framework ids like `#content` and
`#etContent` appear once per window, and the fields you are driving end up a dozen
aliases apart with unrelated content wedged between them. Two things address it:

- **grouping is automatic.** With more than one window, `ui compact` and `ui outline`
  emit a `window <ref> <what> [top]` / `[behind the top window]` header per window,
  topmost first, and indent its nodes under it. Nothing is dropped, and a single-window
  screen is unchanged;
- **`--window top`** (or `--window <ref>`) on any `ui` view narrows the capture to one
  window before rendering — `tree`, `compact`, `outline`, `style`, and the `@N`
  numbering that follows from the outline, all together. That is usually what you
  want: the screen the user is looking at, several-fold cheaper to read.

Prefer scoping over filtering `occluded-by:` yourself. That marker is overloaded —
it also means "under the keyboard" and "under a popup in the SAME window", which
are different situations with different responses.

**`--live` — inspect the running app without writing a report.** Any `ui` view
(`node`/`compact`/`tree`/`regions`/`style`) takes `--live --package <pkg>` instead of a
snapshot path: it pulls the CURRENT tree straight from the runtime and prints it,
writing nothing to disk. Use it for the cheap "what does that one node say right
now?" check — no 300-node report to grep:

```bash
reticle ui node    --live --package <pkg> --resource-id rata   # one node, live
reticle ui compact --live --package <pkg>                      # whole screen, live
reticle ui compact --live --package <pkg> --window top          # only the top window
```

## Style evidence (`ui style`)

When the task is "does this match the design", "did the spacing drift", or "does
this hold up on a smaller screen", read `ui style`. It gives, per node: the frame
in raw units AND dp AND a share of the screen; padding, colours, font
size/weight/family/style, line height, letter spacing, text alignment, corner
radius, border; and text sizes additionally in **sp**, which divides out the system
font scale.

```bash
reticle ui style --live --package <pkg>
```

Two things to relay rather than smooth over:

- **`[channel]`** after each value is where it was read (`viewField`,
  `textLayout`, `computedStyle`, `drawableReflect`). A `drawableReflect` value came
  from a background `Drawable` and is the weakest of the four.
- **`! <property> unreadable: <reason>`** means that node HAS the property and no
  channel can read it — NOT that the app left it unset. Reporting it as "not set"
  is the specific mistake this line exists to prevent. Today: Compose
  `background`/`clip`/`border` (`compose-draw-modifier`) and an Android
  `Typeface`'s family name.

**Reticle does not compare.** It emits magnitudes; deciding what they ought to be,
what tolerance passes, and which regions are exempt (status bar, toolbar) is YOUR
call as the caller — state your tolerance and your exemptions explicitly in the
verdict you write, rather than presenting them as something Reticle found.

## Embedded WebView DOM

Reticle folds visible WebView DOM elements into the same snapshot as `domNode`s.
Use CSS selectors when the target is inside a WebView:

```bash
reticle ui node --live --package <pkg> --css '#checkout button.pay'
reticle act tap --package <pkg> --css '#checkout button.pay' --verify 'css=#status'
```

DOM nodes include the screen-space `frame` plus useful `custom` metadata:

- DOM identity: `domTag`, `domId`, `domClass`, `domCssSelector`, `domHref`,
  `domSrc`, `domSrcset`, `domSizes`, `domInputType`.
- Computed layout/style: `domMargin*`, `domStyleDisplay`, `domStyleVisibility`,
  `domStyleOpacity`, `domStylePosition`, `domStyleZIndex`, `domStyleOverflow*`,
  `domStyleColor`, `domStyleBackgroundColor`, `domStyleBackgroundImage`,
  `domStyleFont*`, `domStyleLineHeight`, `domStyleTextAlign`,
  `domStylePadding*`, `domStyleBorder*Width`, `domStyleBorderRadius`,
  `domStyleTransform`, `domStylePointerEvents`.
- Image resources for `<img>`: `domImageCurrentSrc`,
  `domImageNaturalWidth`, `domImageNaturalHeight`, `domImageComplete`.

The DOM bridge is read-only and snapshot-based. It captures the current document's
visible DOM. iframe inner documents, shadow-root internals, pseudo-elements, and
background-image intrinsic dimensions are boundaries unless explicitly added
later. CSS `background-image` itself is still visible as `domStyleBackgroundImage`.

**Third-party WebView kernels have no DOM at all.** The bridge is typed on
`android.webkit.WebView`, so an X5/TBS or UC kernel (a class that calls itself a
WebView but is not the platform one) cannot be attached to: no `--css`, no styles,
no piercing, at any level. This is structural, not a transient degrade — retrying
or waiting will never produce DOM nodes. Reticle reports it instead of looking
like an empty page: the node carries `dom:unsupported-kernel` (with the class name
in `custom.domKernel`), and a `--css` miss on such a screen says so. Target those
views as plain views (`--test-id` / `--point`); their in-page content is only
reachable if the app exposes it some other way. iOS is unaffected — there is one
web engine.

## Acting on the app

Selector resolution is semantic-first, then view-tree frames, then a raw
point — pass `--test-id`, `--resource-id`, `--css`, `--ref`, or `--point x,y`.
On Android, a node's `testId` is filled from the first of: Compose `testTag` /
classic `view.tag` string (React Native's `testID` writes this), React Native's
`nativeID` (a keyed view tag), then the resource-id entry name — so RN screens
with `testID` or `nativeID` props are targetable by `--test-id` without any
resource ids. When a selector cannot be resolved, Reticle reports candidates
from the current snapshot (matching selector kind: test ids, resource ids, CSS
selectors, or refs) so retry with one of the listed stable handles instead of
guessing coordinates.

```bash
reticle act tap   --package <pkg> --test-id checkout.payButton
reticle act tap   --package <pkg> --css '#web-pay'
reticle act swipe --package <pkg> --from 540,1600 --to 540,400 --duration 300
reticle act drag  --package <pkg> --from x,y --to x,y
reticle act scroll-to --package <pkg> --test-id list.item40   # then tap it
reticle act tap   --package <pkg> --label "Delete item"       # framework rows/menu items
reticle act tap   --package <pkg> --label "Delete item" --settle  # popup still sliding in: full budget
reticle act tap   --package <pkg> --test-id row.a --no-settle     # skip the default re-resolve
reticle act type  --package <pkg> --test-id checkout.name --text "Ada"
reticle act type  --package <pkg> --text "你好 / Zażółć"   # non-ASCII OK
```

`window: UNFOCUSED` in a compact means another window — very likely another
process's, e.g. a permission prompt — holds input focus. Nothing in the tree is
tappable in that state, and the prompt itself is NOT in the tree (out of process, by
design). Deal with the prompt first; don't retry taps.

`--label` is for controls the framework builds without ids: `Spinner` dropdown rows
and `PopupMenu` items share one resource id, and a `UIAlertAction` can't take one at
all. It matches visible text / the a11y label (exact, then substring) in the topmost
window and **refuses an ambiguous match** rather than tapping the first candidate.
Two matches that are NOT an ambiguity: a nested duplicate (a row container repeating
its child's text — the innermost wins), and several views stacked on the same rect
(an iOS `UIPickerView` draws its magnifier bands as separate table views, so a row
near the selection exists 2-3× at one spot). The second reports
`source=label:coincident`, so you can see the match was layered. Prefer `--test-id`
whenever the app owns the control.

**A selector `tap` re-resolves its point before dispatching, by default.** Between
resolving a selector and synthesizing the touch the screen can move, and the touch
then lands on the neighbour while the command reports a plain success — the worst
shape of failure, because the wrong thing *did* change convincingly. Two triggers,
same hazard: the target is animating in (`PopupWindow` / `Spinner` / `PopupMenu`),
or an EARLIER command relayouted the page (a `type` that raised the keyboard, a
`hide-keyboard`, a scroll — measured on a device: a form row's rect was 161px stale
and the tap opened the sheet of the row below it). So every selector tap now
confirms the point repeats before dispatching and reports:

- `settled=1` — confirmed at rest; `settled=0` — still moving when the budget lapsed,
  so this tap may have been aimed at a point that had already changed;
- `rectMoved=<dx>,<dy>` — **only when the first read was stale**. The confirm fixed
  the tap, and this says the screen you reasoned about had already moved.

`--settle` still exists and now means *this target IS animating*: it raises the
budget from 800ms to 2s (`--settle-timeout <ms>` overrides either). `--no-settle`
opts out and dispatches on the single read. A raw `--point` never confirms (nothing
to re-resolve; `--point --settle` is refused). Know the limit: it watches the resolved POSITION, so a view that animates in place with a
transform/alpha — an iOS `UIAlertController`, whose accessibility frame is final
immediately — reports `settled` at once while still not being hit-testable. There,
wait (or `--verify` and retry); no position signal can tell you.

**Wheel columns (`wheel:opaque` / `wheel:selection-only`).** A wheel paints its
candidate values onto its own canvas, so "1995" exists as pixels and nowhere else:
there is no node to tap, no `scroll:` travel, and `scroll-to` can never converge
because no selector for an unselected value will ever resolve. The marker on the
compact line is the cue to switch tactics — without it three rectangles read as
decorative empty views. `selection-only` (an Android `NumberPicker`) means the
CURRENT value is readable as a node and its neighbours are not; `opaque` (a
self-drawn/third-party wheel) means nothing inside it is readable at all. Either
way the recipe is the same:

1. `swipe` along the column's centre, endpoints derived from its frame — not a
   hardcoded distance, which is device- and widget-specific;
2. take the **app's own committed state** as the verdict (`ui compact` on the
   status/summary the app renders, or `debug logs`), never the wheel's own node;
3. repeat until it reads what you want. Do **not** `act type` into a wheel — on
   Android that succeeds and lies (the `EditText` shows the typed text while the
   widget's value stays put until it validates on focus change).

iOS is the asymmetric twin: `UIPickerView` builds a real subview per visible row,
so its neighbours ARE nodes and a `--label` tap on one selects it.

A recycling / lazy list binds only its visible window, so a far-down row has **no
node at all** — `tap` can never reach it and a "not found" there does not mean the
app lacks the element. Scrollable containers report their remaining travel
(`scroll:up,down` in `ui compact`), and `act scroll-to` drags one until the
selector resolves inside it, confirms the position stopped moving (`settled=1`),
and reports the point the next command can use. If the container runs out of
travel it fails loudly — that is the honest "nothing under that selector came into
view", not a claim about the app.

`act type` types **any** text. Give it a targeting selector (`--test-id`,
`--css`, `--point`, …) and it taps that field first so the text lands in *that*
field; with no selector it types into whatever currently holds focus. Text is
**inserted at the cursor** (standard Android input) — it does not clear the
field, so clear first (or mutate the value) when you need replacement rather
than appending. ASCII goes through `adb input text` and works even on apps that
don't link/inject the agent. Non-ASCII (CJK, accented Latin, emoji — which
`adb input text` silently drops) is staged on the device clipboard by the
in-process agent and pasted, so it **requires a reachable runtime**.

**`type` verifies FOCUS, not just dispatch (Android).** After tapping the target
field it reads the tree back and reports `focusLanded=`:

- `self` / `descendant` — the field, or an input inside it, took focus. Normal;
- `ancestor` — the platform focus is on a host view (a WebView with the caret in a
  DOM input, an `AndroidComposeView` with a Compose `TextField` focused). As precise
  as those platforms allow, and treated as landed;
- `unknown` — no focus reading was available (runtime unreachable, older agent).
  Reported, never enforced;
- `none` / `elsewhere` — **the command fails instead of typing.** The text would go
  nowhere, or into a different field, while reporting `chars=N`.

The shape this exists for: a form row where the outer container carries the unique
test id and the real `EditText` inside it reuses one generic id. The container is
then the only handle a selector can name, and a tap on it focuses nothing —
`keyboardVisible` cannot stand in for the check either, since some IMEs render no
window and it reads 0 in the working case too. When the container holds **exactly
one** focusable input, `type` re-aims at it once and reports `retargetedTo=<ref>`;
with two it refuses rather than guessing which field you meant. `ui compact` marks
the focused node ` focused`, and `ui node` carries `isFocusable` per node.

**`type` also reads the TEXT back (Android).** `chars=N` counts what was *sent*.
A field that reformats its value on every change (and re-renders something bound
to it) can lose characters out of the `adb input text` burst: measured,
`--text "10000"` reported `chars=5` into a field that ended up holding `100`,
while the field beside it took all five. So the result also carries `textLanded=`
and the field's actual `text=`:

- `exact` — the typed text is in the field, verbatim;
- `reformatted` — everything you sent is there plus the app's own formatting
  (`10000` → `10,000`). Not a loss;
- `partial` — a proper prefix landed; `landedChars=N` says how much;
- `none` — the field did not change at all;
- `changed` — the text changed into something not derivable from what was sent
  (uppercasing, masking, a `maxLength` rewrite). The app transforming its own
  input is not a defect and Reticle does not call it one — read `text=` and judge;
- `unreadable` — no read-back was possible; `textReadback=unavailable:<reason>`
  names why (no text channel on the field, runtime unreachable, field gone).
  **Never** a claim that it landed.

On `partial` / `none` — and only when the field was empty to begin with — `type`
clears it and re-sends the text over the clipboard, which the app sees as one
change rather than a run of keystrokes, then re-reads. It says so in `recovery=`;
it never retries silently, and it never retries a `changed` (that would be
fighting the app). `--type-delay <ms>` sends one character at a time with that
gap if you would rather avoid the burst than recover from it.

**Every `act` reports a toast the action raised (Android).** An app rejecting a
submit usually says so with `Toast.makeText`, and on Android 11+ that toast is
drawn by the SYSTEM in a window of its own — it is in no tree, in no in-process
screenshot, takes no focus, and cannot be waited for. It used to leave the step
reading `0 change(s)`, i.e. exactly like a tap that hit nothing. The result now
carries:

- `toast="…"` + `toastKind=text` — the message, from the system Toast Queue;
- `toastKind=custom-view` — a `Toast.setView` toast: the app drew it, so the queue
  record has no text and **the text is a node in the tree** (`ui compact` shows it);
- `toastDuration=short|long`, and `toastCount=` when an action raised more than one.

An in-app overlay (a view a "toast library" adds through `WindowManager`) is not a
`Toast` at all: it never enters the queue, is reported as no toast, and needs no
help — it is an ordinary node. A toast raised by ANOTHER process (the system's
"Screenshot saved") is filtered out rather than attributed to your app. The watch
costs ~25ms of `adb shell`; `--no-toast-probe` turns it off.

Add `--submit` to press the keyboard's action key after the text lands —
Android performs the focused field's IME editor action in-process (Done / Next
/ Go / Search / Send; the exact hook React Native's `onSubmitEditing` listens
for), falling back to `KEYCODE_ENTER` when the agent is unreachable; iOS sends
a HID Return. For OTP/login flows this replaces the `type` → `hide-keyboard` →
`tap submit` three-step with one command.

## Waiting for an async boundary (`act wait`)

`--verify` can only watch a node that **already** resolves, so "tap, then a NEW
screen appears" is inexpressible with it. `act wait` is that primitive — the one
`act` gesture that dispatches no input. Use it instead of a blind sleep whenever a
network call, navigation transition, or animation sits between two steps.

```bash
reticle act wait --package <pkg> --for '#cart.total'                 # appear
reticle act wait --package <pkg> --for '#spinner' --gone             # disappear
reticle act wait --package <pkg> --for '#checkout.status' --text 'Paid'
reticle act wait --package <pkg> --idle                              # screen stops changing
reticle act wait --package <pkg> --for 'css=#pay' --timeout 15000
```

`--for` takes the same token grammar as `--verify` (`#testId`, `@resourceId`,
`css=…`, `ref=…`, a bare ref), or use the ordinary `--test-id` / `--css` flags.
It refuses `--point` (a raw coordinate always "resolves", so there is nothing to
wait for) and `--alias` (an alias describes the screen a wait exists to watch
change). Use `--idle` when you do **not** know the next screen's selectors yet —
that is the case a blind sleep was covering.

**Read the outcome, which is three-state, not two:**

| Outcome | Means | Do this |
| --- | --- | --- |
| `RESOLVED` | The predicate held. The very next `act` resolves the same way | Proceed — but read `caveats:` |
| `ABSENT` | It did not hold, and nothing prevented seeing it. An honest negative | You may act on this ("it is not there") |
| `UNKNOWABLE` | It did not hold, and it **could not have been seen** | Switch tactics per `reasons:`. Conclude NOTHING about the app |

The distinction is the whole point: `UNKNOWABLE` shows up when another process's
window holds focus, a list has not bound the row, a DOM is unreadable, a `--label`
is ambiguous, or the screen never settled. Treating it as `ABSENT` is how you end
up reporting a working feature as broken.

`caveats:` never change the outcome but must not be ignored — chiefly
`occluded-by:keyboard` (it resolved, and a tap would still land on the keyboard)
and `resolved-but-not-visible`. The success test is **resolution through the same
path an `act` uses**, not visibility, which is why a covered or hidden-but-targetable
node still reports `RESOLVED`.

Every result carries the predicate it was given, `polls`/`treeChanges`, whatever
`observedText` was actually on the node, and a `next:` line with concrete
follow-up commands. A timeout is **not** a failure: `--json` stays
`{"ok":true,…}`. For shell/CI, `--strict` projects the outcome onto exit codes
(`0` resolved, `3` absent, `4` unknowable — 3 and 4 are deliberately distinct).

Use `act batch --file steps.json` for short, deterministic multi-step flows.
A `wait` step works inside a batch like any other gesture — this is the usual way
to make a recorded flow deterministic instead of sleep-padded. Add
`"strict": true` to make the step a **gate**: the batch stops there if the
predicate did not resolve (without it, the batch records the outcome and carries
on). Note the wire name `textContains`, so a wait step can never be misread as a
`type`:

```json
[
  { "gesture": "tap",  "testId": "checkout.payButton" },
  { "gesture": "wait", "testId": "checkout.status", "textContains": "Paid", "strict": true },
  { "gesture": "tap",  "testId": "checkout.done" }
]
```

## The system keyboard (IME) — state and dismissal

The keyboard is **another process's window**: it never appears in the node
tree, and nodes it covers still read as `tappable`. Reticle surfaces it in
three places so you never tap into the keys by accident:

- Every snapshot carries `screen.keyboard` (`visible` + screen-coordinate
  `frame`), and `ui compact` leads with a `keyboard: visible … (dismiss with
  \`act hide-keyboard\`)` header when it's up.
- Compact items whose tap point is covered are marked `occluded-by:keyboard`
  — the same marker used when a dialog/popup window covers a background item
  (`occluded-by:<windowRef>`). Never tap an occluded item; dismiss the
  occluder first (hide the keyboard, or act inside the top window).
- `act type` results include `keyboardVisible=true/false` when the runtime is
  reachable — typing almost always leaves the keyboard up over the bottom of
  the screen (submit buttons live there).

```bash
reticle act type --package <pkg> --test-id login.code --text "123456"
# … keyboardVisible=true
reticle act hide-keyboard --package <pkg>   # in-app IMM dismiss; reports wasVisible + settled state
reticle act tap  --package <pkg> --test-id login.submit
```

`act hide-keyboard` uses the in-process InputMethodManager (deterministic;
answers with the settled post-hide state). If the agent is unreachable it falls
back to `KEYCODE_ESCAPE`, which — unlike a BACK key — does not navigate back
when the keyboard is already gone.

All of this works identically on iOS (`--target ios`): the agent tracks the
keyboard notification stream and dismisses via `resignFirstResponder`, so
`act hide-keyboard` needs no HID surface and works on real devices too.
Simulator caveat: with "Connect Hardware Keyboard" enabled (Simulator.app
I/O > Keyboard), iOS never shows the software keyboard at all — disable it
and reboot the sim device if `keyboardVisible` stays false after typing.
The file is a JSON array; each object is one normal act RPC using helper-style
keys. **Every selector a single `act` takes works in a step** — `testId`,
`resourceId`, `css`, `ref`, `point` ("x,y"), `alias`, `region` — plus `text`
and `submit` for type, `from`/`to`/`duration` for swipe/drag, `verify`, and
optional `delayMs` after that step:

```json
[
  { "gesture": "type", "testId": "checkout.name", "text": "Ada" },
  { "gesture": "type", "testId": "login.code", "text": "123456", "submit": true },
  { "gesture": "tap", "resourceId": "btnWithdraw" },
  { "gesture": "tap", "testId": "checkout.payButton", "verify": "testId=checkout.status" }
]
```

```bash
reticle act batch --package <pkg> --file steps.json --trace-output reticle-batch
```

Batch is host-side sequencing: it stops on the first failing step and still uses
the same tap/swipe/drag/type backend as individual `act` commands.

**`--verify` — act and check the result in one command.** Add `--verify` to any
`act` and Reticle captures the watched node before the gesture, acts, then polls
until it changes (or a ~2s budget elapses) and prints the before→after diff.
Bare `--verify` watches the node you're acting on; `--verify <selector>` watches a
*different* node (tap a control, watch its effect). This is the "tap → did it
change?" loop in one call — no follow-up `ui report` + grep:

```bash
reticle act tap --package <pkg> --test-id submit --verify              # watch the tapped node
reticle act tap --package <pkg> --point 292,1273 --verify "@rata"      # tap a tab, watch #rata
#   => verify @rata: changed (1 field)
#        text: 3414,20 zł -> 6072,49 zł
```

A selector token is `#testId`, `@resourceId`, or a bare `ref` (the key=
spellings `testId=…`, `resourceId=…`, `ref=…` work too). "No change" is an
honest result, not a failure — it means the node didn't move within the budget
(raise it with `--verify-timeout <ms>`). For WebView DOM nodes, use
`css=<selector>` as the verify token:

```bash
reticle act tap --package <pkg> --css '#style-target' --verify 'css=#style-target'
```

## Action traces

**Every `act` records by default** — no flag, no `serve` needed. Reticle writes
one subdirectory per action under the current session containing:

- `trace.json` — manifest with gesture, selector, resolved point/source/ref, the
  gesture's own inputs (`params`, including a `type`'s text), and a ranked
  before→after diff.
- `before.snapshot.json` / `after.snapshot.json` — full trees around the action.
- `before.screenshot.png` / `after.screenshot.png` when the agent screenshot path
  is available.

Pass `--trace-output <dir>` only to put the artifacts somewhere specific (a bug
report, a `replay gif` input). `RETICLE_NO_AUTO_TRACE=1` turns auto-recording off.

**`trace log` — read a run back cheaply.** This is the command to reach for
instead of opening trace files. A snapshot is 100KB+; the digest is a few lines
per action and answers "what did this run do" on its own:

```bash
reticle trace log                       # the current recording
reticle trace log reticle-batch         # or any trace directory
reticle trace log --changes 12 --json   # more per-action detail / machine-readable
```

```
1  19:11:48  tap  testId=checkout.payButton  →540,1176 semantic:testId
    ~ r36 text "Cart: 3 items" → "Paid!" [testId=checkout.status role=text]
    evidence 1785150708052-tap/, 2 snapshots, 2 screenshots

2  19:11:55  tap  testId=scenario.login  →540,2320 semantic:testId
    (no observable change between before and after — usually the gesture hit
     nothing, but an app can also answer out of tree or purely over the network)
```

How to read it:

- `+` appeared, `-` disappeared, `~` changed. The `[testId=… role=…]` names the
  node, so a bare `r36` never needs a snapshot lookup. It is attached once per
  ref, not repeated on that node's other changes.
- Changes are **ranked**, so the ones shown are the ones that mattered:
  appearances and text before geometry, addressable nodes before anonymous
  containers.
- `(no observable change between before and after)` means the action dispatched
  and the screen did not move. That is a real finding — not an empty result — but
  it is **two** findings wearing one face: the gesture reached no handler
  (re-target), or it reached one that answered somewhere a snapshot cannot see
  (do **not** re-target — read the answer). Before concluding a miss, check the
  `! transient message` line below, and consider a purely network answer.
- `! transient message shown: "…"` is a **toast** the action raised, read from the
  system Toast Queue. It leads the step because when an action is answered by a
  toast, the toast IS the answer — and when one is present the empty-diff line
  changes to `(no other observable change …)`, because the gesture demonstrably
  did not miss. `! transient toast raised [custom-view]` means the app drew the
  toast itself, so its text is a node in the changes right below.
- `…N more (…)` is what the digest omitted; `! manifest kept X of Y` is what the
  capture already dropped. Both snapshots stay on disk, so raise `--changes` or
  open the trace directory when you need the rest.

`trace log` reads only. It asserts nothing: to state an expectation use
`act … --verify` or `act wait --strict`.

**`replay gif` — turn a recorded flow into a shareable artifact.** Once a flow
has trace packages on disk, stitch them into a device-framed animated GIF for
bug reports and PR comments — each step shows its before-screenshot with the
gesture drawn on it (tap ring / swipe arrow) and its after-screenshot, captioned
`2/5 tap testId=checkout.payButton · Δ12`:

```bash
reticle act batch --package <pkg> --file steps.json --trace-output reticle-flow
reticle replay gif reticle-flow                      # => reticle-flow/replay.gif
reticle replay gif reticle-flow --output flow.gif --width 480 --frame-ms 600
```

It is host-local (no device needed) and works on Android and iOS traces alike.
Steps recorded without screenshots are skipped with a stderr note.

## Session event bus

Use `reticle serve` when you need a durable local timeline across multiple
commands or a browser-visible evidence panel. It creates
`~/.reticle/sessions/<session>/events.jsonl` and exposes REST/SSE plus a
display-only panel on localhost via Hummingbird:

```bash
reticle serve --session demo --port 9876 --proxy-port 9090
open http://127.0.0.1:9876/panel
curl -N http://127.0.0.1:9876/events/stream
```

When the daemon is running, ordinary `act ...` commands automatically write trace
packages under the current session and publish `action.trace` events. The panel
shows a vertical evidence timeline: screenshot/snapshot evidence cards, actions,
and manifest diffs are flattened into time-ordered nodes. Diff previews rank
visible text/label/state changes ahead of structural churn, and missing
screenshot artifacts show inline failures. Its session picker can switch from the
live current session to static historical sessions under `~/.reticle/sessions`.
When `--proxy-port` is supplied, the daemon also records `network.*` events and
renders them in the panel's network lane. Network cards are grouped by request id
and show method, URL, status, duration, headers, body refs, and text previews for
captured bodies; sensitive header values are redacted. Mocked responses are
marked with a `MOCK` badge and show copyable mock rule/value ids. Use the
filter buttons for MOCK, ERROR, MITM, and TUNNEL when a session has many network
events. Add `--proxy-device --serial <id>` to configure Android global proxy through
`adb reverse`; the daemon restores the previous proxy setting on exit. HTTPS
decryption is opt-in via `--proxy-mitm`
and `--proxy-ssl-hosts`; Reticle generates a local CA under
`~/.reticle/proxy-ca` unless `--proxy-ca-dir` is supplied. Use
`--proxy-install-ca` to push the CA file and open Android Security settings.
Android 11+ still requires the user to confirm CA trust in Settings, and apps
that ignore user CAs or pin certificates remain opaque.

For Android HTTPS debugging, prefer the debug-flavor trust path. Tell the user
explicitly that this requires an app source change and a rebuild/reinstall, but
only affects the debug variant when placed under the debug source set. Add a
debug-only `network_security_config` that trusts user CAs, then reference it
from the debug manifest/application merge:

```xml
<!-- app/src/debug/res/xml/network_security_config.xml -->
<network-security-config>
  <debug-overrides>
    <trust-anchors>
      <certificates src="user" />
      <certificates src="system" />
    </trust-anchors>
  </debug-overrides>
</network-security-config>
```

```xml
<!-- app/src/debug/AndroidManifest.xml, or an equivalent debug-only manifest merge -->
<application android:networkSecurityConfig="@xml/network_security_config" />
```

Do not present root/system CA installation or runtime trust-manager patching as
the default Reticle workflow. Those are environment-specific escape hatches.
The normal path is: debug build trusts user CA, user installs/confirms the
Reticle CA, then Reticle runs `--proxy-mitm --proxy-ssl-hosts <host>`.

Use `reticle rule` only while `reticle serve` is running. Rule configuration is
stored under the current session as separate rule/value files: `rules.json`,
`rule-values.json`, and `rule-values/<valueId>.body`. A rule chooses traffic
(`method`, `url`, `match`, `priority`) and applies an **action**; a mock action
points at a reusable value that owns the fixed response (`status`, `headers`,
body file). Rules can also be narrowed with `--host api.example.test` or
`--host '*.example.test'`, and `--query '{"page":"1"}'` requires those query
key/value pairs while allowing extra query parameters.

Pick the action with `--action` (defaults to `mock`, or `mapRemote` when
`--map-to` is present):

- `mock` — reply with a stored value (network stub / canned response).
- `block` — fail the connection (network-failure evidence).
- `mapRemote --map-to https://staging.example.com [--keep-host-header]` — re-target
  the request at another origin, keeping path + query.
- `passthrough` — fetch upstream unchanged (only useful with a modifier below).

Modifiers compose with any action: `--delay-ms 3000` (latency, for loading/timeout
states), `--set-request-headers '{"X-Debug":"1"}'` / `--remove-request-headers
'["Authorization"]'` (and the `-response-` variants), and `--request-subs` /
`--response-subs` (a JSON array of `{field,match,replacement[,isRegex,caseSensitive]}`
find/replace substitutions).

```bash
reticle rule set --id users --action mock --value-id users-ok \
  --method GET --url /api/users --match prefix --priority 100 \
  --status 200 --headers '{"Content-Type":"application/json"}' \
  --body '{"users":[]}'
reticle rule set --id kill-analytics --action block --method ANY --url /track --match prefix
reticle rule set --id to-staging --map-to https://staging.example.test \
  --method ANY --url /api --match prefix
reticle rule set --id slow-home --action passthrough --delay-ms 3000 \
  --method GET --url /api/home --match prefix
reticle rule disable --id users
reticle rule value set --id users-ok --status 500 --body '{"error":"down"}'
reticle rule test --method GET --url 'http://api.test/api/users?page=1'
reticle rule export --output /tmp/reticle-rules.json
reticle rule clear
reticle rule import --input /tmp/reticle-rules.json
reticle rule list
```

Use `--body` for inline UTF-8 text. Use `--body-file <path>` for files; the CLI
sends file bytes as base64 so binary or non-UTF-8 mock bodies survive
export/import.

For HTTP traffic, rules apply directly in the host proxy. For HTTPS, they only
apply after MITM decryption (`--proxy-mitm --proxy-ssl-hosts <host>` plus app CA
trust, normally via the debug-only `network_security_config` above); opaque
CONNECT tunnels cannot be path/body-modified. If a mock rule matches but
its value is missing, Reticle records `network.error` and returns 502 rather
than silently contacting upstream. `prefix` is a raw string prefix; use `exact`
for short paths when a broader prefix could match unrelated endpoints.
Use `--trace-output <dir>` only when you also want a copy outside the session.
This is useful for longer demos, replayable validation, or tools that want to
consume trace events. Do not start `serve` for a simple one-off screen read;
`ui report`, `ui node --live`, and `act --verify` stay the cheaper default paths
— and actions record either way, so `reticle trace log` can reconstruct the run
afterwards without the daemon.

## Multi-region controls (one View, several tap targets)

Agreement rows, "highlight = link" text, and self-drawn controls pack several
targets into one node. List them, then tap a specific phrase/link by substring:

```bash
reticle ui regions reticle-report/snapshot.json
reticle act tap --package <pkg> --test-id agreement --region "Privacy"
reticle act tap --package <pkg> --test-id agreement --region "Terms"
```

`ui regions` reports `span` / `colorSpan` / `textMarker` regions (with rects and
link color) and flags `suspectedMultiRegion` self-drawn controls that are still
targetable by substring via the char grid. A `colorSpan` is a *candidate* link
(colored text) — weigh it, don't assert it.

Links that live inside ONE declarative text node work the same way on both
platforms: a Compose `Text` with `LinkAnnotation`s (Android) and a SwiftUI
markdown `Text` (iOS) each capture as a single node, and their links come back as
`span` sub-regions with a char grid — so `--region "Privacy"` is the way in, not
a separate selector. On iOS that geometry is **reconstructed** from the element's
accessibility attributed label (fonts + link runs), so treat the rects as
accurate-enough-to-tap rather than exact.

Region matching is plain substring matching and is **script-agnostic** — pass
whatever text appears on screen, in any language (e.g. `--region "Política"`).
The `textMarker` channel splits self-drawn rows on paired bracket delimiters
across scripts (the markdown `[text](url)` form, plus quote/title brackets like
`«…»` and `《…》`).

## Logs and live UI patching

```bash
reticle debug logs --package <pkg>               # app-authored runtime logs
reticle mutate --package <pkg> --test-id <id> --property text       --value "New label"
reticle mutate --package <pkg> --test-id <id> --property textColor  --value "#FFE53935"
reticle mutate --package <pkg> --test-id <id> --property textSize   --value "72"
reticle mutate --package <pkg> --test-id <id> --property backgroundColor --value "#FF0000"
```

Mutations are allowlisted (`text`, `textColor`, `textSize`, `backgroundColor`,
`alpha`, `visibility`, `enabled`), run in-process, and are NOT persisted — a
rebind or restart reverts them. Compose nodes are intentionally immutable here;
drive declarative UI through the app's own state.

## Honest boundaries (what no retry will fix)

Some things are structurally out of reach for an in-process observer. Reticle
reports each one instead of returning a plausible-looking nothing, so read the
marker rather than concluding the screen is empty. **If you see one of these, stop
and switch tactics — retrying, waiting, or re-capturing will not change it.**

| You see | It means | Do this |
| --- | --- | --- |
| `window: UNFOCUSED …` | Another process's window (permission prompt, biometric sheet, share sheet, Custom Tab) has input focus. It is in NO node of the tree and NOT in the agent's screenshot | Deal with that window first; don't tap into the void |
| `dom:unavailable` | The DOM could not be read *at this moment* (a JS modal blocking the page thread, JS off, budget) | Dismiss the modal / re-capture — this one CAN clear |
| `dom:unsupported-kernel` | A third-party WebView kernel (X5/UC). There is no DOM for it at any level | Target it as a plain view (`--test-id` / `--point`); `--css` will never match |
| `pixels:unavailable` | These pixels are missing from the in-process screenshot (Android `SurfaceView`, iOS keyboard window) | Use a device-level capture if you need the picture |
| `screencap:blank` | A `FLAG_SECURE` window blanks device-level captures | Use the in-process capture (`--package`, agent up) |
| `occluded-by:<ref>` / `occluded-by:keyboard` | Something is on top of your target's tap point | Dismiss it (`act hide-keyboard`) or target the thing on top |
| `scroll:up,down` on a container + selector miss | The row may simply not be bound yet | `act scroll-to`, then tap |
| `act wait` → `UNKNOWABLE` | The predicate did not hold, and the screen was in a state where it could not have been seen. **Not** a negative | Read `reasons:` and switch tactics — never conclude the app lacks the thing |

Also structural, with no marker because there is nothing to mark: a **closed**
shadow root (the host element is captured, its contents are not — open roots ARE
pierced), a **cross-origin iframe** (browser policy; same-origin frames are
pierced), **text baked into a bitmap** (no OCR — that would be a guess dressed as
an observation; a Lottie is the exception, its text layers are recovered), and a
**pure-Canvas control** that exposes no accessibility surface at all (only its rect
and coordinates exist). `docs/architecture.md` has the full table with what pins
each one.

## Rules

- Verify with evidence: check the changed node/state after an action — don't
  claim success from the tap alone. Prefer the cheap paths: `act … --verify` to
  see the before→after diff in the acting command, `reticle trace log` to read
  back what a whole run did, or `ui node --live` to read one node. Fall back to a
  full re-`ui report` only when you need the whole tree.
- A dispatched action is not a landed one — but an empty diff is **two** findings
  wearing one face, so do not report it as a miss on its own. `trace log` printing
  `(no observable change between before and after …)` means either the gesture
  reached no handler (re-target) or it reached one that answered where a snapshot
  cannot see: a toast, a purely network round trip, another process's window.
  Check the `! transient message shown:` line first — with a toast recovered the
  wording changes to `(no other observable change …)`, which is evidence the
  gesture did NOT miss.
- If the runtime is unreachable (app not linked / not injected), report that
  honestly; never fabricate a tree or coordinates. For a debuggable app without
  the AAR, try `reticle app inject --package <pkg>` before giving up.
- Authorized testing only: injecting into an app you don't own requires explicit
  authorization. Default to the bundled `sample-app` for demos.

For architecture, the Compose-semantics boundary, and the region/char-grid
design, see `${CLAUDE_PLUGIN_ROOT}/docs/architecture.md` and
`${CLAUDE_PLUGIN_ROOT}/AGENTS.md`.
