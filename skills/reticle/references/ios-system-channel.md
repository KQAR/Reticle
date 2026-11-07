# The system channel — another process's UI, on a real iOS device

`ui` and `act` read and drive the app **from inside it**, so everything outside its
own windows is structurally invisible to them: a permission alert, the keyboard's
own window, SpringBoard, Home. `reticle system …` is the second channel, and the
only one that reaches those. It has two backends:

- **host** (default) — driven from this Mac over a CoreDevice tunnel by
  `reticle-device`, which ships beside the CLI. Touch and Home go through a HID
  connection backboardd routes into any process, and reads come from the device's
  own cross-process accessibility tree. **Nothing is installed on the device**: no
  runner, no signing team, no resident process.
- **runner** (`--via runner`) — a resident out-of-process XCUITest runner
  (`reticle-runner-ios`). Use it when the host channel is unavailable, or when you
  need an XCUITest property the device tree does not carry.

**Real iOS devices only**, and `--target ios` is required (`the system channel is
iOS-only; pass --target ios`). There is no Android analogue and none is needed —
on Android that layer is reached with `adb`.

Keep the two apart when reporting. A system read answers about a *different*
process on a *thinner* channel; its results are `SystemObservation` / `SystemNode`,
never the app's `Node`, and every read leads with `channel=…  process=…` for
exactly that reason. Never merge a system tree into an app tree, and never quote a
system node as evidence about the app under test.

## Setup

Host channel: none. The device has to be attached over **USB**, unlocked, trusted
and in **developer mode** with the developer disk image mounted (attaching it to
Xcode once does that). Check it with:

```bash
reticle --target ios system status --serial <udid>   # ready / unavailable missing=[…]
```

The first host command starts a resident session for the device (tunnel, display
stream and HID connections kept open), so the HID part of a later tap is ~50 ms; a
tree read is still ~1.7–2.4 s, so a tap with its before/after reads is ~4–5 s. The session
ends after 2 minutes idle, on any error (the next command starts a new one), or on
`system stop`. A from-source CLI needs `cargo` to build
`reticle-device`; without it, use `--via runner`.

Runner channel (`--via runner`), once per device:

```bash
reticle --target ios system prepare --serial <udid> --team <signing-team-id>
reticle --target ios system status  --serial <udid> --via runner   # notInstalled / installed / connected
```

`prepare` builds, signs and installs the runner on that device. It needs the
**Reticle repo checkout** (the runner is an xcodegen project — generate it with
`xcodegen generate` inside `reticle-runner-ios/` if `ReticleRunner.xcodeproj` is
missing), Xcode, and a signing team that exists on this machine — a missing
`--team` is answered with the usable ones. Point elsewhere with
`RETICLE_RUNNER_PROJECT=<path to ReticleRunner.xcodeproj>`. It runs once per
device, not per session: after it, any `system` command starts the runner itself.

The device must be **unlocked**, and *Settings → Developer → Enable UI Automation*
must be on. Starting the runner takes the foreground; when a command started it,
the read says so with `warning:runner-started-mid-command`, so an interference you
would otherwise attribute to the app is stated instead of guessed at.

```bash
reticle --target ios system stop --serial <udid>   # release the device
```

A runner built before it opted out of XCTest's diagnostic screen recording left
one video per session on the phone (gigabytes of "System Data", untouched by a
reboot). `reticle --target ios doctor` measures it on each reachable device (`--json`:
`xctestAttachments`) and, above 1 GB, prints the `devicectl` command that clears it.

## Reading

```bash
reticle --target ios system overlay                    # what is covering the app right now
reticle --target ios system tree                       # the topmost overlay (default)
reticle --target ios system tree home                   # SpringBoard
reticle --target ios system tree com.example.other      # a named app
reticle --target ios system screenshot --out shot.png   # display-level PNG
```

`overlay` has a positive empty answer — `overlay: none — nothing is covering the
app right now` — so "clear" and "the read failed" are never the same output.

`system screenshot` is the **display-level** picture (`framing=display-level`): it
includes the status bar, another process's sheet and the keyboard's own window,
all of which the in-process `ui screenshot` on a device structurally cannot show.

**What this channel cannot see** is printed once per read
(`unreadable by this channel: …`): view class name, Compose semantics, WebView DOM,
computed style, interaction regions, `checked`/`expanded`/`isFocusable`, and
visibility. A property missing here means *this channel cannot see it*, never that
the app lacks it — read those through `ui` / `act` on the app's own tree.

**The host channel reads only what is on screen.** With a system modal up, the
device reports SpringBoard holding the modal's texts and buttons and nothing else,
so `overlay` means "SpringBoard is in front and is not the home screen". `tree home`
and `tree <bundle-id>` answer only when that process is in front; otherwise they
are refused with what IS in front. It has no hit test, so `isHittable` is listed
as unreadable, and home-screen icons read as `unrecognized:44`.

**Runner reads are expensive**: every attribute is a cross-process query (a WebView tree
took 126s, measured). Reads are bounded by node count and depth, default to the
topmost overlay only, and declare truncation (`truncated: returned=… limit=…
reason=…`). Ask for a bigger target by name, and expect a Home-screen read to be
slow.

## Driving

```bash
reticle --target ios system tap --label "Allow"      # a labelled control on the system layer
reticle --target ios system tap --point 120,480      # absolute screen coordinate
reticle --target ios system home                     # backgrounds the app under test
reticle --target ios system activate --package <bundle-id>   # foreground it again, no restart
```

An action reports `dispatched` and `changed` **separately**, so "delivered but
nothing moved" is a stateable outcome rather than a success. A refusal lists what
*is* on the system layer instead of failing blank.

`system home` really does background the app under test — its loopback socket goes
with it, so bring it back with `system activate --package <bundle-id>` (which does
not restart it, unlike `app launch`) before the next `ui` / `act` command.

### Typing into an app without the agent (host only)

```bash
reticle --target ios system tap --point <x,y>        # focus the field first
reticle --target ios system type --text "hello 你好"  # paste into the focused field
```

`system type` puts the text on the device pasteboard, presses Cmd+V, answers the
paste prompt iOS raises (`Allow Paste` / `允许粘贴`), and reads the field back:
`textLanded=` uses `act type`'s words (`exact`, `reformatted`, `changed`, `none`, …)
with `before=`/`after=`, or `unreadable:<why>` (a secure field, several fields
changing). The user's pasteboard is saved first and put back
(`pasteboard=restored`); plain text and one image can be restored, anything else is
listed in `pasteboardLost=[…]` and the pasteboard is left `cleared`. Any OTHER modal
stops it with that modal's controls. Use it only for an app that does not link the
agent; with the agent, `act type` inserts in-process with no prompt. Measured: ~9 s
per call (three tree reads and a prompt).

## When NOT to use it

For anything inside the app under test. The in-app channel sees far more and costs
far less, and on a real device it can already tap, swipe, drag, `scroll-to` and
type in-process. Reach for `system` only when the target is not the app's own UI —
or when the honest answer would otherwise be `window: UNFOCUSED`.
