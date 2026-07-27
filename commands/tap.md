---
description: Tap an element in the running app (Android or iOS) by selector, then verify the result.
argument-hint: <package> <selector> [--target ios]  e.g. dev.reticle.sample --test-id scenario.checkout
---

Tap an element in the running app. Parse `$ARGUMENTS` as a package name followed
by a selector: `--test-id`, `--resource-id`, `--css`, `--ref`, `--label`, or
`--point x,y`, optionally with `--region "<substring>"` to hit one phrase or link
inside a multi-region control.

Follow the **`reticle` skill** for selector choice, the resolution order, and how
to read a verify diff. The short form:

1. If the selector is not already known, capture evidence first —
   `reticle ui report --package <pkg> --output reticle-report`, then `ui compact`
   (and `ui regions` for multi-region rows) to pick a stable handle.
2. Dispatch and check the post-condition in one command:
   `reticle act tap --package <pkg> <selector> --verify [<#testId|@resourceId|css=…|ref>]`.
   Bare `--verify` watches the tapped node; pass a selector to watch a different
   one (tap a tab, watch the value it updates).
3. **Report success only with the diff as evidence.** The result names how it
   resolved (`semantic:testId`, `region:span`, `charGrid`, …) — a `charGrid` hit is
   an approximation, not a semantic match. If `--verify` says "no change", say so
   and suggest a next step; never claim success from the tap alone.

Two refusals are answers rather than errors to work around: a `--label` matching
several visible nodes, and a `--region` matching no phrase, both stop instead of
guessing and both name what they did see. Narrow the selector rather than falling
back to coordinates.

The tap is recorded either way — a per-action directory with `trace.json`,
before/after snapshots and screenshots. `reticle trace log` reads it back in a
few lines; add `--trace-output reticle-traces` only to put the artifacts
somewhere specific. `--target ios` selects an iOS simulator or device; a real iOS
device has no coordinate tap — use `act activate` with a selector there.
