---
description: Tap an element in the running Android app by selector, then verify the result.
argument-hint: <package> <selector>  e.g. dev.reticle.sample --test-id scenario.checkout
---

Tap an element in the running Android app using the bundled `reticle` CLI.

Parse `$ARGUMENTS` as a package name followed by a selector. The selector is one
of `--test-id <id>`, `--resource-id <id>`, `--css <selector>`, `--ref <ref>`, or
`--point x,y`, and may include `--region "<substring>"` to hit a specific
phrase/link inside a multi-region control.

Steps:
1. If unsure of the exact selector, first capture evidence:
   `reticle ui report --package <pkg> --output reticle-report` and inspect
   `reticle ui compact reticle-report/snapshot.json` (and `ui regions` for
   multi-region controls) to pick the right selector. For embedded WebViews,
   inspect a DOM target with `reticle ui node reticle-report/snapshot.json --css
   '<selector>'`.
2. Dispatch the tap, verifying the result in the same command:
   `reticle act tap --package <pkg> <selector> --verify [<#testId|@resourceId|ref>]`
   The resolver prints which path it used (semantic / view frame / region / char
   grid), then `--verify` prints the watched node's before→after diff. Bare
   `--verify` watches the tapped node; pass a selector to watch a different one
   (e.g. tap a tab or WebView button, watch the value it updates).
3. Report success only with that diff as evidence. If `--verify` says "no change",
   say so and suggest next steps — don't claim success from the tap alone. For a
   broader check use `reticle ui node --live --package <pkg> <selector>` (one
   node, no files) or a full `reticle ui report …`.
