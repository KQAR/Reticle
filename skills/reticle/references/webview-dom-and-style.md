# WebView DOM and style evidence

Read this when the target is inside a WebView, or when the question is about
computed style / geometry rather than which node to tap. Back to
[SKILL.md](../SKILL.md).

## Style evidence (`ui style`)

When the task is "does this match the design", "did the spacing drift", or "does
this hold up on a smaller screen", read `ui style`. It gives, per node: the frame
in raw units AND dp AND a share of the screen; padding, colours, font
size/weight/family/style, line height, letter spacing, text alignment, corner
radius, border; and text sizes additionally in **sp**, which divides out the system
font scale.

```bash
reticle ui style --live --package <pkg>
```

Two things to relay rather than smooth over:

- **`[channel]`** after each value is where it was read (`viewField`,
  `textLayout`, `computedStyle`, `drawableReflect`). A `drawableReflect` value came
  from a background `Drawable` and is the weakest of the four.
- **`! <property> unreadable: <reason>`** means that node HAS the property and no
  channel can read it — NOT that the app left it unset. Reporting it as "not set"
  is the specific mistake this line exists to prevent. Today: Compose
  `background`/`clip`/`border` (`compose-draw-modifier`) and an Android
  `Typeface`'s family name.

**Reticle does not compare.** It emits magnitudes; deciding what they ought to be,
what tolerance passes, and which regions are exempt (status bar, toolbar) is YOUR
call as the caller — state your tolerance and your exemptions explicitly in the
verdict you write, rather than presenting them as something Reticle found.

## Embedded WebView DOM

Reticle folds visible WebView DOM elements into the same snapshot as `domNode`s.
Use CSS selectors when the target is inside a WebView:

```bash
reticle ui node --live --package <pkg> --css '#checkout button.pay'
reticle act tap --package <pkg> --css '#checkout button.pay' --verify 'css=#status'
```

DOM nodes include the screen-space `frame` plus useful `custom` metadata:

- DOM identity: `domTag`, `domId`, `domClass`, `domCssSelector`, `domHref`,
  `domSrc`, `domSrcset`, `domSizes`, `domInputType`.
- Computed layout/style: `domMargin*`, `domStyleDisplay`, `domStyleVisibility`,
  `domStyleOpacity`, `domStylePosition`, `domStyleZIndex`, `domStyleOverflow*`,
  `domStyleColor`, `domStyleBackgroundColor`, `domStyleBackgroundImage`,
  `domStyleFont*`, `domStyleLineHeight`, `domStyleTextAlign`,
  `domStylePadding*`, `domStyleBorder*Width`, `domStyleBorderRadius`,
  `domStyleTransform`, `domStylePointerEvents`.
- Image resources for `<img>`: `domImageCurrentSrc`,
  `domImageNaturalWidth`, `domImageNaturalHeight`, `domImageComplete`.

The DOM bridge is read-only and snapshot-based. It captures the current document's
visible DOM. iframe inner documents, shadow-root internals, pseudo-elements, and
background-image intrinsic dimensions are boundaries unless explicitly added
later. CSS `background-image` itself is still visible as `domStyleBackgroundImage`.

**Third-party WebView kernels have no DOM at all.** The bridge is typed on
`android.webkit.WebView`, so an X5/TBS or UC kernel cannot be attached to. This is
structural, not a transient degrade — retrying or waiting will never produce DOM
nodes. The node carries `dom:unsupported-kernel` with the class name in
`custom.domKernel`, so it never looks like an empty page. iOS is unaffected —
there is one web engine.
