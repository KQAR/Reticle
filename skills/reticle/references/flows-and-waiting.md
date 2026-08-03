# Multi-step flows and async boundaries

Read this when a check spans several steps, or when the thing you assert on
arrives late (a network call, a navigation, an animation). Back to
[SKILL.md](../SKILL.md).

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

A `wait` step also works inside `act batch` — see **`act batch`** below; that is
the usual way to make a recorded flow deterministic instead of sleep-padded.

## `act batch` — deterministic multi-step flows

Use `act batch --file steps.json` for short, deterministic multi-step flows.
The file is a JSON array; each object is one normal act RPC using helper-style
keys. **Every selector a single `act` takes works in a step** — `testId`,
`resourceId`, `css`, `ref`, `point` ("x,y"), `alias`, `region` — plus `text`
and `submit` for type, `from`/`to`/`duration` for swipe/drag, `verify`, and
optional `delayMs` after that step.

A `wait` step works inside a batch like any other gesture. Add `"strict": true`
to make it a **gate**: the batch stops there if the predicate did not resolve
(without it, the batch records the outcome and carries on). Note the wire name
`textContains`, so a wait step can never be misread as a `type`:

```json
[
  { "gesture": "type", "testId": "checkout.name", "text": "Ada" },
  { "gesture": "type", "testId": "login.code", "text": "123456", "submit": true },
  { "gesture": "tap",  "testId": "checkout.payButton", "verify": "testId=checkout.status" },
  { "gesture": "wait", "testId": "checkout.status", "textContains": "Paid", "strict": true },
  { "gesture": "tap",  "resourceId": "btnWithdraw" }
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
