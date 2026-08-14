---
description: Verify a flow end to end against the running app (Android or iOS) — drive it, then assert on the evidence Reticle captured.
argument-hint: <package> <what to verify> [--target ios]  e.g. dev.reticle.sample checkout pays and the status turns Paid
---

Verify a flow against the app that is **actually running**. Parse `$ARGUMENTS` as
a package name followed by the flow to check in prose; default package
`dev.reticle.sample`, or `dev.reticle.sampleios` when `--target ios` is passed.

This is the command the rest of Reticle exists for: **Reticle produces evidence,
you do the asserting.** Nothing below emits a verdict on its own — a dispatched
gesture is not a landed one, and an unchanged node is a finding rather than an
error. Follow the **`reticle` skill** for selector choice, the health-check
decision table, and what each marker means.

1. **Runtime up.** `reticle doctor`, then `reticle status --package <pkg>`. Use the
   skill's table to classify UNREACHABLE / UNRESPONSIVE / CONFLICT / FOREIGN; a
   debuggable Android app that does not link the AAR needs
   `reticle app inject --package <pkg>` first. No device or no runtime — stop and
   say so rather than describing what the app probably does.
2. **Baseline.** Do what `/reticle:report` does, into `reticle-verify/before`
   (capture + `ui compact`, plus `ui regions` when a step targets one phrase of a
   multi-region row). What this step adds: pick the stable handles the run will
   use — `#testId` / `@resourceId` / `css=` — and say which ones you chose. A
   selector invented from a screenshot is not a selector.
3. **Drive it with the post-conditions attached.** Prefer one
   `reticle act batch --package <pkg> --file steps.json --trace-output reticle-verify/trace`:
   put `"verify"` on the steps whose effect you are claiming, and make the
   decisive waits gates with `"strict": true` so the batch stops at the first
   step that did not land instead of running past it. For a one-step check,
   `reticle act <gesture> … --verify [<selector>]` is the same loop in one call.
4. **Read the run back.** `reticle trace log reticle-verify/trace` — the
   step-by-step before→after diffs, in a few lines, without re-capturing the tree.
5. **Assert, step by step.** For each step: what you expected, the diff (or the
   marker) that settles it, and PASS / FAIL. Quote the field that changed
   (`text: 3414,20 zł -> 6072,49 zł`), not a summary of it.

Relay the markers as `/reticle:report` does. What only matters once a step is
being *claimed*: an empty diff is two findings wearing one face (the gesture
missed, *or* it landed and the app answered out of tree / over the network) — say
which one the trace supports, or that it cannot tell them apart. `window:
UNFOCUSED` voids the step under it: nothing in that tree was tappable, so the
step proves nothing either way. A `charGrid` resolution is an approximation, not a
semantic match.

End with a verdict that a reader can check: the failing step (if any), the
artifacts path, and — when a boundary blocked the check rather than the app
failing it — that distinction, stated.

Every command above accepts `--target ios` for a simulator or a real device. On a
real iOS device every gesture is synthesized inside the app (`via=agent uikit`), so
taps, `--region` taps, swipe, drag, `scroll-to` and `type` all work — what does not
is UI the app does not own, and the in-process screenshot omits it too (the status
bar, the keyboard's window, another process's sheet). For that layer the skill's
`references/ios-system-channel.md` is the path; `ui outline` and `--alias @N` are
Android-only, so pick iOS handles with `ui compact --live`.
