---
description: Capture a Reticle runtime UI report from a running app (Android or iOS) and summarize what's on screen.
argument-hint: <package> [--target ios]  e.g. dev.reticle.sample
---

Capture a runtime UI report for the app named by `$ARGUMENTS` and summarize the
screen. Default package: `dev.reticle.sample`, or `dev.reticle.sampleios` when
`--target ios` is passed.

Follow the **`reticle` skill** for the full workflow — the health-check decision
table, the evidence-reading rules, and what each marker means. This command is
that workflow applied to one screen:

1. `reticle doctor` — if no device, stop and say so.
2. Bring the runtime up: `reticle app launch --package <pkg>`. On failure use
   `reticle status --package <pkg>` to classify why; the skill maps UNREACHABLE /
   UNRESPONSIVE / CONFLICT / FOREIGN to its fix. A debuggable Android app that
   does not link the AAR needs `reticle app inject --package <pkg>` instead; the
   skill's health-check table has the rest. Report a failure honestly rather than
   fabricating output.
3. `reticle ui report --package <pkg> --output reticle-report`.
4. `reticle ui compact reticle-report/snapshot.json` — summarize the interactive
   and labelled elements, including embedded WebView DOM nodes.
5. `reticle ui regions reticle-report/snapshot.json` — call out multi-region
   controls (agreement rows, link runs) and how to target each phrase.
6. For a WebView target that matters: `reticle ui node
   reticle-report/snapshot.json --css '<selector>'` for computed styles, margins,
   image URLs and natural size.

Report the on-screen elements, any multi-region nodes, relevant DOM metadata, and
the report path. **Relay the evidence markers instead of smoothing them over**:
`window: UNFOCUSED` means nothing in this tree is tappable right now,
`dom:unavailable` / `dom:unsupported-kernel` mean the web content was not read,
`scroll:up,down` means a missing row may simply be unbound. `docs/boundaries.md`
says what each marker means and whether a retry can help.

Every command above accepts `--target ios` for an iOS simulator or device.
