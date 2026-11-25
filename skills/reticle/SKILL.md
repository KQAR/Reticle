---
name: reticle
description: >-
  Inspect and drive a RUNNING Android or iOS app from its live runtime, not its
  source or a screenshot. Use when the task involves an app on a connected
  device / emulator / simulator and you need to: read the on-screen view /
  semantic / Jetpack Compose or SwiftUI accessibility tree or embedded WebView
  DOM, find a stable selector or exact tap coordinates, tap/swipe/type real
  input, target a specific phrase or link inside a multi-region control (e.g. an
  agreement row), inspect DOM CSS styles or image resources, read back what a
  recorded run did (`trace log`), show a read-only local Web panel for a
  multi-action evidence timeline, mock or replay network traffic, read app
  runtime logs, or live-patch a UI property (text/color/size/visibility) without
  rebuilding. iOS needs `--target ios`; on a real iOS device gestures are
  synthesized in-process, and another process's UI (a permission alert,
  SpringBoard, Home) is reached only through the separate `system` channel.
  Triggers: "what's on screen", "drive the app", "change this label at runtime",
  adb/UiAutomator/Espresso/XCUITest-style UI verification.
metadata:
  reticle-stub: "1"
---
<!-- The plugin's copy of the stub "reticle skill setup" writes. The guide is in the CLI. -->

Run `reticle skill show` and follow the guide it prints. The guide comes from
the installed Reticle CLI, so it describes the commands available in that
version. It points at deeper topics; print one with `reticle skill show <topic>`.

If `reticle` is not on PATH, it is not installed (macOS 15+ arm64):
`curl -fsSL https://raw.githubusercontent.com/KQAR/Reticle/main/install.sh | bash`.
If `reticle skill show` fails, the installed CLI predates the guide: run
`reticle update`.
