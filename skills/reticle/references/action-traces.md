# Action traces

Read this to reconstruct what a run did — the per-action evidence packages,
`trace log`, and the replay renderer. Back to [SKILL.md](../SKILL.md).

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
