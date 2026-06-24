---
description: Capture a Reticle runtime UI report from a running Android app and summarize what's on screen.
---

Use the bundled `reticle` CLI to capture a runtime UI report for the Android app
identified by `$ARGUMENTS` (a package name; if empty, use `dev.reticle.sample`,
the bundled demo).

Steps:
1. Run `reticle doctor` to confirm adb and a connected device/emulator. If no
   device, stop and tell the user.
2. Run `reticle app launch --package <pkg>` to launch + forward + wait for the
   in-process runtime. If it times out, the app likely doesn't link the
   reticle-agent — report that honestly (see the reticle skill for injection
   options) instead of fabricating output.
3. Run `reticle ui report --package <pkg> --output reticle-report`.
4. Run `reticle ui compact reticle-report/snapshot.json` and summarize the
   interactive/labelled elements on screen.
5. Run `reticle ui regions reticle-report/snapshot.json` and call out any
   multi-region controls (agreement rows, link runs) and how to target them.

Report the on-screen elements, any multi-region nodes, and the report path.
