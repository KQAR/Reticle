# The system channel — another process's UI, on a real iOS device

`ui` and `act` read and drive the app **from inside it**, so everything outside its
own windows is structurally invisible to them: a permission alert, the keyboard's
own window, SpringBoard, Home. `reticle system …` is the second channel, and the
only one that reaches those. It is a resident out-of-process XCUITest runner
(`reticle-runner-ios`), granted a backboardd HID connection an in-process agent
never gets.

**Real iOS devices only**, and `--target ios` is required (`the system channel is
iOS-only; pass --target ios`). There is no Android analogue and none is needed —
on Android that layer is reached with `adb`.

Keep the two apart when reporting. A system read answers about a *different*
process on a *thinner* channel; its results are `SystemObservation` / `SystemNode`,
never the app's `Node`, and every read leads with `channel=…  process=…` for
exactly that reason. Never merge a system tree into an app tree, and never quote a
system node as evidence about the app under test.

## One-time setup

```bash
reticle --target ios system prepare --serial <udid> --team <signing-team-id>
reticle --target ios system status  --serial <udid>   # notInstalled / installed / connected
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

**Reads are expensive**: every attribute is a cross-process query (a WebView tree
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

## When NOT to use it

For anything inside the app under test. The in-app channel sees far more and costs
far less, and on a real device it can already tap, swipe, drag, `scroll-to` and
type in-process. Reach for `system` only when the target is not the app's own UI —
or when the honest answer would otherwise be `window: UNFOCUSED`.
