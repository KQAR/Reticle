---
description: Inject the Reticle runtime into a running debuggable Android app that does not link the agent AAR, over JDWP (no repackage, no root).
argument-hint: <package>  e.g. com.example.app
---

Use the bundled `reticle` CLI to start the Reticle runtime inside a **debuggable**
app that does NOT link the `reticle-agent` AAR, by injecting a payload dex over
the app's JDWP debugger channel. Works with no repackage and no root — even on
locked `user` builds where `wrap.sh` is blocked. The package is `$ARGUMENTS` (if
empty, use `dev.reticle.sample.noagent`, the bundled agent-free demo flavor).

Steps:
1. Run `reticle doctor` to confirm adb and a connected device/emulator. If no
   device, stop and tell the user.
2. Make sure the target app is **running** — injection attaches to a live
   process. If `reticle status --package <pkg>` shows it's not running, launch it
   (open it on-device, or `adb shell monkey -p <pkg> -c
   android.intent.category.LAUNCHER 1`).
3. Run `reticle app inject --package <pkg>`. On success it prints
   `runtime live: … port=…`. If it fails, relay the message honestly:
   - "is the app debuggable?" — only debuggable builds expose JDWP; a
     non-debuggable release needs Frida/root, not this path.
   - "payload dex not found" — build it with
     `./gradlew :reticle-agent:dexPayload`, or set `RETICLE_PAYLOAD_DEX`.
   - a handshake/JDWP stall — set `RETICLE_JDWP_DEBUG=1` and retry for a trace;
     another debugger (Android Studio) attached to the same pid blocks it.
4. Confirm it took: `reticle ui report --package <pkg> --output reticle-report`
   should return a non-empty tree. After injection every other command
   (`ui`/`act`/`mutate`/`debug logs`) works against the app unchanged.

Authorized testing only — injecting into an app you don't own requires explicit
authorization. Report the runtime port and that the app is now drivable.
