---
description: Tap an element in the running Android app by selector, then verify the result.
argument-hint: <package> <selector>  e.g. dev.reticle.sample --test-id checkout.payButton
---

Tap an element in the running Android app using the bundled `reticle` CLI.

Parse `$ARGUMENTS` as a package name followed by a selector. The selector is one
of `--test-id <id>`, `--resource-id <id>`, `--ref <ref>`, or `--point x,y`, and
may include `--region "<substring>"` to hit a specific phrase/link inside a
multi-region control.

Steps:
1. If unsure of the exact selector, first capture evidence:
   `reticle ui report --package <pkg> --output reticle-report` and inspect
   `reticle ui compact reticle-report/snapshot.json` (and `ui regions` for
   multi-region controls) to pick the right selector.
2. Dispatch the tap:
   `reticle act tap --package <pkg> <selector> [--region "…"]`
   The resolver prints which path it used (semantic / view frame / region
   / char grid).
3. Verify: re-run `reticle ui report …` and confirm the expected state change
   in the affected node (`reticle ui node …`). Report success only with that
   evidence; if nothing changed, say so and suggest next steps.
