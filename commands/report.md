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
   in-process runtime. If it fails or times out, run `reticle status --package
   <pkg>` to classify why (UNREACHABLE = agent not linked / app not running;
   UNRESPONSIVE = stale socket, force-stop + relaunch; CONFLICT = another app
   holds the port). If the app is debuggable but doesn't link the agent
   (UNREACHABLE with no Reticle logcat lines), try `reticle app inject --package
   <pkg>` (the app must be running) to start the runtime over JDWP, then continue.
   Otherwise report that honestly instead of fabricating output.
3. Run `reticle ui report --package <pkg> --output reticle-report`.
4. Run `reticle ui compact reticle-report/snapshot.json` and summarize the
   interactive/labelled elements on screen, including embedded WebView DOM nodes.
5. Run `reticle ui regions reticle-report/snapshot.json` and call out any
   multi-region controls (agreement rows, link runs) and how to target them.
6. For WebView nodes that matter, run
   `reticle ui node reticle-report/snapshot.json --css '<selector>'` to inspect
   DOM metadata such as computed styles, margins, image URLs, and natural image
   size.

Report the on-screen elements, any multi-region nodes, relevant WebView DOM
selectors/metadata, and the report path.
