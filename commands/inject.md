---
description: Start the Reticle runtime inside a running app that does not link the agent — over JDWP on Android (no repackage, no root), DYLD on an iOS simulator.
argument-hint: <package> [--target ios]  e.g. com.example.app
---

Start the Reticle runtime inside an app that does **not** link the agent. The
package is `$ARGUMENTS`; if empty use `dev.reticle.sample.noagent`, the bundled
agent-free flavor. On Android this loads a payload dex over the app's JDWP channel
— no repackage, no root, and it works on locked `user` builds where `wrap.sh` is
blocked. With `--target ios` it uses `DYLD_INSERT_LIBRARIES` on a simulator.

Follow the **`reticle` skill** for what to do after the runtime is up. The
injection path itself:

1. `reticle doctor` — if no device, stop and say so.
2. The app must already be **running**: injection attaches to a live process. If
   `reticle status --package <pkg>` says it is not, launch it (on-device, or
   `adb shell monkey -p <pkg> -c android.intent.category.LAUNCHER 1`).
3. `reticle app inject --package <pkg>`. Success prints `runtime live: … port=…`,
   which means the server *answered*, not merely that the invoke returned.
4. Confirm with `reticle ui report --package <pkg> --output reticle-report`. After
   this every other command (`ui` / `act` / `mutate` / `debug logs`) works against
   the app unchanged.

Relay a failure with its reason instead of retrying blindly:

- **not debuggable** — only debuggable builds expose JDWP; a non-debuggable
  release needs Frida/root, which is out of scope by design.
- **payload dex not found** — `./gradlew :reticle-agent:android:dexPayload`, or set
  `RETICLE_PAYLOAD_DEX`.
- **slow first inject (up to ~15s) on a just-launched app** — expected, not a
  hang: a fresh debug process briefly refuses new JDWP attaches, and inject waits
  that window out. An `EOFException` right after launch is usually this; give the
  process a few seconds and a screen touch, then retry.
- **another debugger attached** (Android Studio on the same pid) blocks it. For a
  real trace, set `RETICLE_JDWP_DEBUG=1` and retry.

Authorized testing only — injecting into an app you do not own requires explicit
authorization. Report the runtime port and that the app is now drivable.
