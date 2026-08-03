# The system keyboard (IME)

Read this when typing is involved, a field will not focus, or something on screen
is hidden behind the keyboard. Back to [SKILL.md](../SKILL.md).

The keyboard is **another process's window**: it never appears in the node
tree, and nodes it covers still read as `tappable`. Reticle surfaces it in
three places so you never tap into the keys by accident:

- Every snapshot carries `screen.keyboard` (`visible` + screen-coordinate
  `frame`), and `ui compact` leads with a `keyboard: visible … (dismiss with
  \`act hide-keyboard\`)` header when it's up.
- Compact items whose tap point is covered are marked `occluded-by:keyboard`
  — the same marker used when a dialog/popup window covers a background item
  (`occluded-by:<windowRef>`). Never tap an occluded item; dismiss the
  occluder first (hide the keyboard, or act inside the top window).
- `act type` results include `keyboardVisible=true/false` when the runtime is
  reachable — typing almost always leaves the keyboard up over the bottom of
  the screen (submit buttons live there).

```bash
reticle act type --package <pkg> --test-id login.code --text "123456"
# … keyboardVisible=true
reticle act hide-keyboard --package <pkg>   # in-app IMM dismiss; reports wasVisible + settled state
reticle act tap  --package <pkg> --test-id login.submit
```

`act hide-keyboard` uses the in-process InputMethodManager (deterministic;
answers with the settled post-hide state). If the agent is unreachable it falls
back to `KEYCODE_ESCAPE`, which — unlike a BACK key — does not navigate back
when the keyboard is already gone.

All of this works identically on iOS (`--target ios`): the agent tracks the
keyboard notification stream and dismisses via `resignFirstResponder`, so
`act hide-keyboard` needs no HID surface and works on real devices too.
Simulator caveat: with "Connect Hardware Keyboard" enabled (Simulator.app
I/O > Keyboard), iOS never shows the software keyboard at all — disable it
and reboot the sim device if `keyboardVisible` stays false after typing.
