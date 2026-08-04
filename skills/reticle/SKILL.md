---
name: reticle
description: >-
  Inspect and drive a RUNNING Android or iOS app from its live runtime, not its
  source or a screenshot. Use when the task involves an app on a connected
  device / emulator / simulator and you need to: read the on-screen view /
  semantic / Jetpack Compose or SwiftUI accessibility tree or embedded WebView
  DOM, find a stable selector or exact tap coordinates, tap/swipe/type real
  input, target a specific phrase or link inside a multi-region control (e.g. an
  agreement row), inspect DOM CSS styles or image resources, read back what a
  recorded run did (`trace log`), show a read-only local Web panel for a
  multi-action evidence timeline, mock or replay network traffic, read app
  runtime logs, or live-patch a UI property (text/color/size/visibility) without
  rebuilding. iOS needs `--target ios`; on a real iOS device the paths are
  observation + in-process activation, not HID.
  Triggers: "inspect the running app", "tap the … button on device", "what's on
  screen", "drive the app", "find the element", "test the agreement checkbox",
  "change this label at runtime", adb/UiAutomator/Espresso/XCUITest-style UI
  verification.
---

# Reticle — runtime UI evidence + action harness (Android + iOS)

Reticle inspects the app that is **actually running** and drives real input. It
runs a tiny HTTP server inside the app process (loopback) and a host CLI talks to
it — over `adb forward` on Android, the shared host loopback on an iOS simulator,
`iproxy` over USB on an iOS device. Prefer Reticle over guessing from screenshots
when you need precise selectors, coordinates, or live UI state.

The CLI is on PATH as `reticle` while this plugin is enabled.

## What is here, and what to open when

This file is the whole read-and-drive path: bring the runtime up, capture a
screen, pick a selector, act, and read the markers. The heavier machinery lives in
`references/` next to this file — **read one only when its row describes what you
are doing**, since none of it is needed to inspect a screen or tap a button:

| Open | When |
| --- | --- |
| `references/flows-and-waiting.md` | The check spans several steps (`act batch`, gates), or what you assert on arrives late (`act wait`) |
| `references/action-traces.md` | You need to reconstruct what a run did — evidence packages, `trace log`, replay |
| `references/keyboard.md` | Typing is involved, a field will not focus, or the keyboard is covering the target |
| `references/webview-dom-and-style.md` | The target is inside a WebView, or the question is computed style / geometry |
| `references/daemon-and-panel.md` | A run needs a durable timeline across many commands, a browser-visible panel, or network capture |
| `references/network-rules.md` | The app must see a different network — mock, block, map to another origin, add latency |

## Install (how the `reticle` binary is obtained)

`reticle` is the **Swift host** — a no-JDK native macOS 14+ arm64 binary that drives
Android through a sibling native helper (`reticle-helper`). **macOS 14+ arm64 only.**
Two things matter operationally: the default path **always** uses the
SHA256-verified prebuilt release — there is **no silent source build** — and a
failed download **hard-stops** with actionable guidance instead of quietly
building from source. `reticle version` confirms it's ready.

The full launcher resolution order and its env overrides (`RETICLE_HOST`,
`RETICLE_HOME`, `RETICLE_FROM_SOURCE`, `RETICLE_REPO`) are documented once, in
`README.md` → **How the CLI is obtained**.

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
in complementary ways and each says so (`pixels:unavailable`, `screencap:blank` —
see **Honest boundaries** below for which path to switch to). `ui screenshot`
prints a `degraded:` line for whatever the picture it just wrote is missing.

On **iOS** the fallback is narrower, so say which path produced the picture:
`reticle --target ios ui screenshot --package <bundle-id> --output shot.png`
prints `via agent` or `via simctl`. The device-level path is `simctl io`, which is
**simulator-only** — on a **real device** the agent's in-process render is the only
source (over the `iproxy` tunnel; the app must be foreground, since a suspended app
loses its loopback socket). So on a device, anything that is not this app's own
window is simply absent with nothing to switch to: the **status bar**, the system
keyboard's host window, another process's sheet. Report that as a boundary, never
as "the screen was empty."

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
reticle ui coverage --live --package <pkg>       # what share of this screen has no selector over it, and why
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

`compact` also **caps the list at 200 items** (`ui style` at 500), and a capped
run ends with `(N more item(s) beyond this projection's cap …)` — unlike a fold,
those items are not printed at all, so never read a compact carrying that line as
the whole screen; reach the rest with `ui tree` / `ui node --ref`.

`ui outline --live --package <pkg>` is the fastest ad-hoc agent loop: it prints
**on-screen** labelled/interactive nodes as `@1`, `@2`, ... — on screen, not merely
in the tree: it used to number the whole scrollable content, and measured on a real
home screen that was 135 aliases whose last entry sat at y=10800 on a 2412-tall
device, about 15 of them actually visible. A row below the fold is reached with
`act scroll-to` and then re-outlined. and writes a short-lived
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
reticle ui compact --package <pkg>                             # same thing: no path means live
```

`--package <pkg>` with no snapshot path already implies `--live`, so the flag is
optional; it is kept for scripts that pass it. A path, when given, always wins.

A WebView target, or a question about computed style / box geometry rather than
which node to tap: `references/webview-dom-and-style.md` (`ui style`, `ui node
--css`, how DOM nodes fold into the tree).

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
guessing coordinates. With no selector at all the miss names `--label` first — the
visible string is the only handle a good many framework controls have.

**A flag a command does not read is an error, not a no-op.** `act tap --text "Tak"`
used to answer `could not resolve selector '<empty>'`, because unparsed flags were
dropped; it now reports `unknown option --text for \`act tap\`` and names the
commands that do take it (`act type`, `act wait`). Applies to `status`, `app`, `ui
*`, `act *`, `mutate` and `debug`; `rule` / `replay` / `trace` / `serve` are not
flag-validated.

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

**`--css` matches, it does not string-compare.** It used to be an equality test
against each node's captured `domCssSelector` — the whole ancestor path — so only a
verbatim copy of that path resolved and every short form here missed on a real
page. Supported now: type, `#id`, `.class` and their compounds, with descendant,
child (`>`) and pierce (`>>>`) combinators, plus `:nth-of-type(n)` /
`:nth-child(n)`; a full captured path still matches verbatim too. Anything else —
attribute selectors, every other pseudo-class, `*`, sibling combinators, selector
lists — is **refused by name** rather than answered as a miss, because "not
understood" and "no such element" lead to opposite next actions. A miss lists only
candidates that share part of the query, by their shortest handle.

`:nth-of-type(n)` is the family the captured paths are built out of, so a path can
be **shortened or re-aimed by hand** instead of pasted whole:

```bash
reticle ui node --live --package <pkg> --css 'div.row:nth-of-type(2) input'   # the 2nd row's input
reticle act type --package <pkg> --css 'div.row:nth-of-type(3) input' --text "…"
```

The index is the position the **page** reported, not a count of captured siblings:
the DOM walk drops `display:none` elements, so counting would answer
`:nth-of-type(3)` with the third *visible* sibling. Only a plain 1-based index is
implemented — `:nth-of-type(2n+1)` and keyword arguments are refused by name.

`--label` is for controls the framework builds without ids: `Spinner` dropdown rows
and `PopupMenu` items share one resource id, and a `UIAlertAction` can't take one at
all. It matches visible text / the a11y label (exact, then substring) in the topmost
window that has a match and **refuses an ambiguous match** rather than tapping the
first candidate.
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

**A coordinate tap says why it had to be one.** Every `--point` tap carries a
coverage verdict, printed as a `warning:` line, and both answers are actionable:

- `warning: no semantic selector covers (x,y) — <reason>: …` — the fallback was
  justified, and the reason names what is in the way (`iframe:cross-origin`,
  `dom:capped(N)`, `dom:unavailable`, `dom:unsupported-kernel`, `wheel`,
  `container-only`, `no-interactive-node`, `nothing-captured`). Treat it as the
  filed gap it is: coordinates are the remaining path *for that region only*.
- `warning: --point was not needed at (x,y): --test-id … resolves to rN …` — the
  quieter loss. Something at that point had a handle, so the coordinate threw away
  the re-resolution, the settle confirm and the stale-rect evidence a selector tap
  performs. Re-issue it with the named flag.

A selector tap prints no such line, so the warning always means "a coordinate was
used here".

`ui coverage` asks the same question about the whole screen: it samples on a stated
grid and reports the share of touch-relevant cells with an addressable node over
them, then lists each unreachable region by reason, host ref and rect. Two honest
limits are in the output rather than behind it. A **screen-sized tappable
container** (a `WebView`, a scroll host) is not counted as cover for the points
inside it — a selector tap on it lands on its own centre, not where you aimed — so
its interior appears as `container-only`; and cells where a node is captured but
nothing is interactive are reported as `inert` rather than as gaps, because without
pixels a paragraph of text and a control the projection failed to mark are the same
observation.

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
`--label`, `--css`, `--point`, …) and it taps that field first so the text lands in *that*
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

**A form's own state is on the line, not in the screenshot.** `ui compact` renders
four things a form screen otherwise made you look at pixels for:

- ` checked` / ` unchecked` / ` checked:mixed` — a checkable control's state. A node
  that is **not** checkable prints nothing here, and that silence is the third
  answer: "there is no checkbox" and "there is a checkbox and it is unticked" lead
  to opposite next actions. Sources are readings, not guesses — an Android
  `Checkable` view, Compose's `ToggleableState`/`Selected`, a DOM
  `input[type=checkbox|radio]`, or `aria-checked`/`aria-pressed` on a control a
  framework built out of divs;
- ` placeholder:"…"` — what an input is *asking* for, kept apart from the quoted
  label, which is what it *holds*. The two used to be folded together, so an empty
  field and a filled one printed identically;
- ` invalid` / ` invalid:"…"` — the field declares itself invalid
  (`aria-invalid`), with the message its `aria-describedby` names. Without it a
  validation error is a sibling node belonging to nothing;
- an `<input>`'s **type is its role**: `checkbox`, `radio`, `slider`, `button` for
  `submit`/`button`/`reset`/`image`. Only a genuine text input reads `textField`;
- ` collapsed` / ` expanded` + ` popup:<kind>` — a control that opens something.
  **This is how a dropdown built out of divs is driven.** Such a control has no
  `<select>`, often no id and no tabindex, and its options do not exist in the DOM
  until it is opened — so before the first tap there is nothing to diff against and
  ` expanded` is the only evidence a tap did anything. `popup:listbox` is also the
  cue that an empty subtree under it is EXPECTED rather than a capture failure. A
  node declaring no disclosure state prints nothing here, which is again the third
  answer.

A click handler bound in JS cannot be read from a page (`getEventListeners` is a
devtools API), so `tappable` on a framework-built control comes from what the page
publishes: a widget `role` (`combobox`, `option`, `treeitem`, …), `aria-haspopup`,
`aria-expanded`, `tabindex`, `onclick` — and, when none of those are declared,
`cursor: pointer`. That last one is the page telling a human "this is clickable"
and is the weakest of them; it is recorded as `custom.domCursor` so you can see
when tappability rested on it. It is applied only at the node where the pointer
**starts**: `cursor` is inherited, so a pointer on a wrapper computes as pointer on
every descendant, and marking all of them would turn one control into four.

`--label` resolves a **caption and the control it names** to the control. One
string legitimately belongs to two nodes in different subtrees (`aria-labelledby`,
`<label for>`) and only one of them does anything when tapped, so the single
*actionable* match wins. Two actionable matches is still a refusal.

A DOM input also carries `custom.domName` (its `name` attribute) and
`custom.domPlaceholder`, and its accessible name resolves through `aria-label` →
`aria-labelledby` → `title`/`alt`. On a form built from framework components — no
`id`, no `data-testid`, no value — those are the only handles that tell several
identical fields apart.

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

**Web forms read back like any other field.** They used to be the one place this
whole check did not apply: every DOM input answered
`unavailable:dom-input-value-not-separable-from-placeholder`, so no `type` into a
web form could be verified and the partial/none recovery — which only fires on a
classified loss — could never fire there at all. Both are gone now that a DOM
input's value and its placeholder are separate fields. Two consequences worth
knowing: an empty input reads as **empty**, not as unreadable (the agents omit a
blank value, so there is no `text` at all), and a DOM node that is not an input
says `unavailable:dom-node-is-not-a-text-input` rather than the generic
"no text field". The read-back also re-reads a DOM field up to three times: the
characters go in through the IME and the page's own handlers run afterwards, so
the first read can legitimately still show the old value.

On `partial` / `none` — and only when the field was empty to begin with — `type`
clears it and re-sends the text over the clipboard, which the app sees as one
change rather than a run of keystrokes, then re-reads. It says so in `recovery=`;
it never retries silently, and it never retries a `changed` (that would be
fighting the app). `--type-delay <ms>` sends one character at a time with that
gap if you would rather avoid the burst than recover from it.

`type --clear` empties the field first — one Delete per character it actually
holds — and reports what that did: `cleared=already-empty`, `cleared=emptied(6ch)`,
or a refusal. It **refuses to type** when the clear did not take (a field longer
than 64 characters, an unreadable field, one whose content survives the deletes),
because typing then appends to what is still there while the result reads like a
clean write. Without `--clear`, `type` inserts at the caret: on a field that
already holds a value that is an append, and on one already at its `maxLength` it
is a no-op the read-back reports as `textLanded=none`.

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

Beyond a single gesture, in the order you usually need them:

- the effect lands late (network, navigation, animation), or the flow is several
  steps that must not run past a failure — `references/flows-and-waiting.md`
  (`act wait`, `act batch` with `"strict"` gates);
- typing, a field that will not focus, or the keyboard covering the target —
  `references/keyboard.md`;
- read back what a whole run did, without re-capturing — `references/action-traces.md`
  (`trace log`, the per-action evidence packages, replay).

Do not start `serve` for a simple one-off screen read;
`ui report`, `ui node --live`, and `act --verify` stay the cheaper default paths
— and actions record either way, so `reticle trace log` can reconstruct the run
afterwards without the daemon. When you do need it (a durable timeline, the
panel, network capture): `references/daemon-and-panel.md`, and
`references/network-rules.md` to make the app see a different network.

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
| `dom:capped(N)` | This web view's DOM walk stopped at the traversal's own node cap after N nodes. Unlike the projection cap, the rest were never captured — no `ui tree` or `ui node --ref` can reach them | Narrow the page, or scroll and re-capture |
| `dom:unavailable` | The DOM could not be read *at this moment* (a JS modal blocking the page thread, JS off, budget) | Dismiss the modal / re-capture — this one CAN clear |
| `dom:unsupported-kernel` | A third-party WebView kernel (X5/UC). There is no DOM for it at any level | Target it as a plain view (`--test-id` / `--point`); `--css` will never match |
| `pixels:unavailable` | These pixels are missing from the in-process screenshot (Android `SurfaceView`, iOS keyboard window) | Use a device-level capture if you need the picture |
| `screencap:blank` | A `FLAG_SECURE` window blanks device-level captures | Use the in-process capture (`--package`, agent up) |
| `occluded-by:<ref>` / `occluded-by:keyboard` | Something is on top of your target's tap point — a higher window, the keyboard, **or a later-drawn sibling in the same window** (a second screen pushed over a still-alive one, which is what a hybrid app does) | Dismiss it (`act hide-keyboard`) or target the thing on top |
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
  wearing one face, so never report it as a miss on its own; read it as described
  under **`trace log`** in `references/action-traces.md`.
- If the runtime is unreachable (app not linked / not injected), report that
  honestly; never fabricate a tree or coordinates. For a debuggable app without
  the AAR, try `reticle app inject --package <pkg>` before giving up.
- Authorized testing only: injecting into an app you don't own requires explicit
  authorization. Default to the bundled `sample-app` for demos.

For architecture, the Compose-semantics boundary, and the region/char-grid
design, see `${CLAUDE_PLUGIN_ROOT}/docs/architecture.md` and
`${CLAUDE_PLUGIN_ROOT}/AGENTS.md`.
