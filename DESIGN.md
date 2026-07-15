---
version: alpha
name: Reticle-web-panel-design
description: "The design source of truth for the Reticle web panel — the zero-build, read-only Evidence Timeline served at GET /panel. A near-black evidence canvas built around #010102 (the Linear dark-surface spec), light gray text (#f7f8f8), and the signature lavender-blue (#5e6ad2) used as the single chromatic accent. The system reads as software-craft documentation: dense, technical, and quietly luxurious. Display type is Inter (SF Pro Display fallback) at 500–600 with measured negative tracking. Cards live as charcoal panels (#0f1011) with hairline borders. The accent lavender appears on focus rings, links, selection, and action markers — never decoratively. Page rhythm leans on evidence screenshots framed in dark panels rather than atmospheric color; the panel's in-product semantic palette (green / amber / red / purple) is confined to timeline markers and status badges."

colors:
  primary: "#5e6ad2"
  on-primary: "#ffffff"
  primary-hover: "#828fff"
  primary-focus: "#5e69d1"
  ink: "#f7f8f8"
  ink-muted: "#d0d6e0"
  ink-subtle: "#8a8f98"
  ink-tertiary: "#62666d"
  canvas: "#010102"
  surface-1: "#0f1011"
  surface-2: "#141516"
  surface-3: "#18191a"
  surface-4: "#191a1b"
  hairline: "#23252a"
  hairline-strong: "#34343a"
  hairline-tertiary: "#3e3e44"
  semantic-success: "#27a644"
  semantic-warning: "#f2c94c"
  semantic-danger: "#eb5757"
  semantic-network: "#b59aff"
  semantic-overlay: "#000000"

typography:
  display-md:
    fontFamily: Inter
    fontSize: 40px
    fontWeight: 600
    lineHeight: 1.15
    letterSpacing: -1.0px
  headline:
    fontFamily: Inter
    fontSize: 28px
    fontWeight: 600
    lineHeight: 1.20
    letterSpacing: -0.6px
  card-title:
    fontFamily: Inter
    fontSize: 22px
    fontWeight: 500
    lineHeight: 1.25
    letterSpacing: -0.4px
  subhead:
    fontFamily: Inter
    fontSize: 20px
    fontWeight: 400
    lineHeight: 1.40
    letterSpacing: -0.2px
  body-lg:
    fontFamily: Inter
    fontSize: 18px
    fontWeight: 400
    lineHeight: 1.50
    letterSpacing: -0.1px
  body:
    fontFamily: Inter
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.50
    letterSpacing: -0.05px
  body-sm:
    fontFamily: Inter
    fontSize: 14px
    fontWeight: 400
    lineHeight: 1.50
    letterSpacing: 0
  caption:
    fontFamily: Inter
    fontSize: 12px
    fontWeight: 400
    lineHeight: 1.40
    letterSpacing: 0
  button:
    fontFamily: Inter
    fontSize: 14px
    fontWeight: 500
    lineHeight: 1.20
    letterSpacing: 0
  eyebrow:
    fontFamily: Inter
    fontSize: 13px
    fontWeight: 500
    lineHeight: 1.30
    letterSpacing: 0.4px
  mono:
    fontFamily: JetBrains Mono
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.50
    letterSpacing: 0

rounded:
  xs: 4px
  sm: 6px
  md: 8px
  lg: 12px
  xl: 16px
  xxl: 24px
  pill: 9999px
  full: 9999px

spacing:
  xxs: 4px
  xs: 8px
  sm: 12px
  md: 16px
  lg: 24px
  xl: 32px
  xxl: 48px
  section: 96px

components:
  top-nav:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    typography: "{typography.body-sm}"
    rounded: "{rounded.xs}"
    height: 56px
  status-line:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink-subtle}"
    typography: "{typography.caption}"
    rounded: "{rounded.xs}"
    padding: 0
  filter-tab-default:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink-subtle}"
    typography: "{typography.button}"
    rounded: "{rounded.pill}"
    padding: 6px 14px
  filter-tab-selected:
    backgroundColor: "{colors.surface-2}"
    textColor: "{colors.ink}"
    typography: "{typography.button}"
    rounded: "{rounded.pill}"
    padding: 6px 14px
  session-picker:
    backgroundColor: "{colors.surface-1}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.md}"
    padding: 8px 12px
  evidence-card:
    backgroundColor: "{colors.surface-1}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.lg}"
    padding: 24px
  screenshot-panel:
    backgroundColor: "{colors.surface-1}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.xl}"
    padding: 24px
  network-card:
    backgroundColor: "{colors.surface-1}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.lg}"
    padding: 24px
  runtime-card:
    backgroundColor: "{colors.surface-1}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.lg}"
    padding: 24px
  facts-cell:
    backgroundColor: "{colors.surface-2}"
    textColor: "{colors.ink-muted}"
    typography: "{typography.caption}"
    rounded: "{rounded.md}"
    padding: 8px 12px
  copy-chip:
    backgroundColor: "{colors.surface-2}"
    textColor: "{colors.ink-muted}"
    typography: "{typography.mono}"
    rounded: "{rounded.sm}"
    padding: 2px 8px
  status-badge:
    backgroundColor: "{colors.surface-2}"
    textColor: "{colors.ink-muted}"
    typography: "{typography.caption}"
    rounded: "{rounded.pill}"
    padding: 2px 8px
  diff-row:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink-muted}"
    typography: "{typography.mono}"
    rounded: "{rounded.xs}"
    padding: 12px 0
  timeline-marker:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.on-primary}"
    typography: "{typography.caption}"
    rounded: "{rounded.full}"
    size: 10px
  lane-label:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink-subtle}"
    typography: "{typography.eyebrow}"
    rounded: "{rounded.xs}"
    padding: 0 0 8px 0
  empty-state:
    backgroundColor: "{colors.surface-1}"
    textColor: "{colors.ink-subtle}"
    typography: "{typography.body}"
    rounded: "{rounded.lg}"
    padding: 48px
  lightbox:
    backgroundColor: "{colors.semantic-overlay}"
    textColor: "{colors.ink}"
    typography: "{typography.caption}"
    rounded: "{rounded.xl}"
    padding: 24px
---

## Overview

The Reticle web panel is a **read-only evidence surface**: it renders session timelines — before/after screenshots, action facts, selector chips, network captures, runtime advisories — so an agent's work can be audited at a glance. Its design system is the Linear dark-surface system applied to an evidence viewer.

The canvas is `{colors.canvas}` #010102 — near-pure black with a faint blue tint, never true black. On top sits a four-step surface ladder (`{colors.surface-1}` through `{colors.surface-4}`) for cards, panels, and lifted tiles, with hairline borders running from `{colors.hairline}` (#23252a) up through `{colors.hairline-strong}` and `{colors.hairline-tertiary}`. Light gray text (`{colors.ink}` #f7f8f8) carries titles and body.

The single chromatic accent is **lavender-blue** `{colors.primary}` (#5e6ad2) — used on the selected filter ring, focus rings, links, and action markers. A lighter hover state (`{colors.primary-hover}` #828fff) and a focus-tinted variant (`{colors.primary-focus}` #5e69d1) extend the same hue. The panel avoids saturated color on chrome; the in-product semantic palette (green / amber / red / purple) exists only as timeline-marker dots, badge text, and thin signal rules.

Display type runs **Inter** (fallback `SF Pro Display, -apple-system, system-ui, Segoe UI, Roboto`) at weight 500–600 with negative letter-spacing scaling from -1.0px at 40px down to 0 at small sizes. **JetBrains Mono** is the machine voice — selectors, URLs, rule ids, diff values.

The page rhythm is **dense evidence screenshots** — the panel leads with high-fidelity captures from the device, framed in `{colors.surface-1}` panels with `{rounded.xl}` 16px corners. The chrome is intentionally minimal so the evidence can do the heavy lifting.

**Key Characteristics:**

- **Dark-canvas evidence system** — `{colors.canvas}` (#010102) is the anchor surface; no light mode.
- **Lavender-blue accent** (`{colors.primary}` #5e6ad2) — used scarcely: selection, focus, links, action markers.
- Four-step surface ladder (canvas → surface-1 → surface-2 → surface-3 → surface-4) carries hierarchy without shadow.
- Display tracking pulls negative (-1.0px at 40px); body holds at -0.05px.
- Cards use `{rounded.lg}` 12px corners with 1px hairline borders — never pill, `{rounded.xl}` 16px only for screenshot panels.
- **Evidence screenshots** dominate the page. The panel chrome is a dark frame for the captures.
- Mono type marks copyable machine facts; prose never renders in mono.
- No second chromatic accent on chrome. No atmospheric gradients. No spotlight cards.

## Colors

> Palette adopted from the Linear dark-surface spec. Implementation target: the `:root` custom-property block in `reticle-host/Sources/ReticleHostCore/WebPanel.swift`.

### Brand & Accent

- **Lavender-Blue** ({colors.primary}): The signature accent — selected filter ring, focus rings, links, action-node markers.
- **Lavender Hover** ({colors.primary-hover}): Lighter lavender (#828fff) — hovered links and hovered interactive chips.
- **Lavender Focus** ({colors.primary-focus}): Focus-ring tint (#5e69d1) — focused session picker, focused filter tab.

### Surface

- **Canvas** ({colors.canvas}): Default page background — #010102, near-pure black with a faint blue tint.
- **Surface 1** ({colors.surface-1}): One step above canvas — evidence cards, network cards, screenshot panels, empty states.
- **Surface 2** ({colors.surface-2}): Two steps above — facts cells, copy chips, badges, selected filter tab, hovered cards.
- **Surface 3** ({colors.surface-3}): Three steps above — session-picker dropdown, sticky sub-headers.
- **Surface 4** ({colors.surface-4}): Four steps above — deepest lifted surface (nested body previews inside cards).
- **Hairline** ({colors.hairline}): 1px borders on cards, dividers, and the timeline rail.
- **Hairline Strong** ({colors.hairline-strong}): Stronger 1px borders — surface-2 elements, input boundaries.
- **Hairline Tertiary** ({colors.hairline-tertiary}): Tertiary borders for nested surfaces.

### Text

- **Ink** ({colors.ink}): Panel title, card titles, primary values — light gray #f7f8f8, never pure white.
- **Ink Muted** ({colors.ink-muted}): Secondary type at #d0d6e0 — facts values, diff cells, chip labels.
- **Ink Subtle** ({colors.ink-subtle}): Tertiary type at #8a8f98 — status line, lane labels, deselected filter tabs, empty-state copy.
- **Ink Tertiary** ({colors.ink-tertiary}): Quaternary at #62666d — timestamps, disabled, footnotes.

### Semantic

Semantic hues appear **only** on timeline markers, badge text, and thin signal rules — never as card fills or large areas.

- **Success Green** ({colors.semantic-success}): Evidence-captured markers, MOCK-hit badges. The Linear semantic green.
- **Warning Amber** ({colors.semantic-warning}): Diff markers, high-signal diff rules.
- **Danger Red** ({colors.semantic-danger}): Error badges, runtime advisory markers.
- **Network Purple** ({colors.semantic-network}): Network-request markers and the network lane identity.
- **Overlay** ({colors.semantic-overlay}): Pure black overlay scrim for the lightbox.

## Typography

### Font Family

- **Inter** — the display and text voice; fallback `SF Pro Display, -apple-system, system-ui, Segoe UI, Roboto`. Carries display-md through caption. (Inter is the recommended open substitute for the Linear custom sans; on macOS the SF Pro fallback is closest.)
- **JetBrains Mono** — the machine voice; fallback `ui-monospace, SF Mono, Menlo`. Carries selectors, URLs, ids, diff values, header/body previews. (The recommended open substitute for Linear Mono.)

Display and text are one continuous voice; the change to mono is meaningful — it marks *machine facts*.

### Hierarchy

| Token | Size | Weight | Line Height | Letter Spacing | Use |
|---|---|---|---|---|---|
| `{typography.display-md}` | 40px | 600 | 1.15 | -1.0px | Empty-state hero, session summary numerals |
| `{typography.headline}` | 28px | 600 | 1.20 | -0.6px | Panel title ("Reticle Evidence Timeline") |
| `{typography.card-title}` | 22px | 500 | 1.25 | -0.4px | Card titles: action name, request method + host |
| `{typography.subhead}` | 20px | 400 | 1.40 | -0.2px | Session summary lead line |
| `{typography.body-lg}` | 18px | 400 | 1.50 | -0.1px | Lead paragraphs in empty states |
| `{typography.body}` | 16px | 400 | 1.50 | -0.05px | Default body, card prose |
| `{typography.body-sm}` | 14px | 400 | 1.50 | 0 | Card meta, session picker, nav links |
| `{typography.caption}` | 12px | 400 | 1.40 | 0 | Timestamps, status line, screenshot captions, badges |
| `{typography.button}` | 14px | 500 | 1.20 | 0 | Filter tabs, interactive chips |
| `{typography.eyebrow}` | 13px | 500 | 1.30 | 0.4px | UPPERCASE lane labels, facts keys (positive tracking) |
| `{typography.mono}` | 13px | 400 | 1.50 | 0 | Selectors, URLs, ids, diff values, body previews |

### Principles

- **Negative tracking on display** (-1.0px at 40px), tapering to 0 at small sizes.
- **Single voice from display to body.** Display at 600 → body at 400 — same family, narrower weights. Weight 600 is the ceiling; nothing renders at 700+.
- **Eyebrow uses positive tracking** (+0.4px, uppercase) — contrast against the negative-tracked display marks the eyebrow as taxonomy: lane labels, facts keys, badge text.
- **Mono only in machine contexts.** JetBrains Mono lives on selectors, URLs, ids, and previews — not on panel chrome or prose.

## Layout

### Spacing System

- **Base unit**: 4px.
- **Tokens (front matter)**: `{spacing.xxs}` 4px · `{spacing.xs}` 8px · `{spacing.sm}` 12px · `{spacing.md}` 16px · `{spacing.lg}` 24px · `{spacing.xl}` 32px · `{spacing.xxl}` 48px · `{spacing.section}` 96px.
- Card interior padding: `{spacing.lg}` 24px on evidence/network/runtime cards and screenshot panels; `{spacing.xxl}` 48px on empty states.
- Filter tab padding: 6px vertical · 14px horizontal — the compact pill spec.
- Form input (session picker) padding: 8px vertical · 12px horizontal.
- Chip padding: 2px vertical · 8px horizontal.

### Grid & Container

- Max content width sits around 1280px, centered, with `{spacing.lg}` 24px page gutters.
- The timeline is a **two-lane grid** around a 1px center rail drawn in `{colors.hairline}`: left lane = UI evidence, right lane = network requests.
- The top nav is sticky, 56px tall, on `{colors.canvas}` with a 1px `{colors.hairline}` bottom rule and `backdrop-filter: blur(12px)`.
- Facts grids inside cards are 3-up at desktop, 2-up at tablet, 1-up at mobile.
- Screenshot panels span the full lane width — they're the protagonist.

### Whitespace Philosophy

The dark canvas IS the whitespace. Nodes separate by lift onto surface-1 panels, not by gaps in white. Within a panel, generous `{spacing.lg}` 24px gaps between content blocks; `{spacing.lg}` 24px of raw canvas between timeline nodes; `{spacing.section}` 96px between sessions when multiple render on one page.

## Elevation & Depth

| Level | Treatment | Use |
|---|---|---|
| 0 (flat) | No shadow, no border | Status line, lane labels, timestamps on canvas |
| 1 (charcoal lift) | `{colors.surface-1}` background on canvas, 1px `{colors.hairline}` | Default cards, screenshot panels, empty states |
| 2 (surface-2 lift) | `{colors.surface-2}` background, 1px `{colors.hairline-strong}` | Chips, badges, facts cells, selected filter tab, hovered cards |
| 3 (surface-3 lift) | `{colors.surface-3}` background | Session-picker dropdown, sub-headers |
| 4 (focus ring) | 2px `{colors.primary-focus}` outline at 50% opacity | Focused input, focused filter tab, keyboard focus anywhere |

Depth is carried by surface ladder + hairline borders. The system resists drop shadows on dark almost entirely — the sole exception is the lightbox dialog (`0 24px 80px rgba(0,0,0,.45)`), which floats above the overlay scrim.

### Decorative Depth

- **Evidence screenshots** dominate as decorative depth — framed, never cropped.
- **No atmospheric gradients, no spotlight cards.**
- **Subtle white edge highlight** on the top edge of lifted panels — gives the dark surface a faint "pixel rendered" feel.
- Timeline markers carry a soft identity ring: `box-shadow: 0 0 0 4px` of the marker color at 10% opacity — the one glow permitted.

## Shapes

### Border Radius Scale

| Token | Value | Use |
|---|---|---|
| `{rounded.xs}` | 4px | Diff rows, small chips, tiny inline tags |
| `{rounded.sm}` | 6px | Copy chips, inline code |
| `{rounded.md}` | 8px | Session picker, facts cells, buttons |
| `{rounded.lg}` | 12px | Evidence / network / runtime cards, empty states |
| `{rounded.xl}` | 16px | Screenshot panels, lightbox dialog |
| `{rounded.xxl}` | 24px | Oversized session-summary banners (rare) |
| `{rounded.pill}` | 9999px | Filter tabs, status badges |
| `{rounded.full}` | 9999px | Timeline markers |

Cards hold at `{rounded.lg}` 12px — never pill, rarely 16px. Pills are reserved for toggles and badges.

### Imagery Geometry

- Evidence screenshots dominate; they sit in `{rounded.xl}` 16px tiles with `{spacing.lg}` 24px outer padding, keep native aspect ratio, and never crop.
- Timeline markers render at 10px diameter, `{rounded.full}`, centered on the rail.

## Components

### Navigation

**`top-nav`** — Sticky dark bar: panel title left, status line + filter tabs center, session picker right.
- Background `{colors.canvas}` with blur, text `{colors.ink}`, type `{typography.body-sm}`, height 56px, 1px `{colors.hairline}` bottom rule.

**`status-line`** — Live connection/session status ("streaming · session abc123").
- Text `{colors.ink-subtle}`, type `{typography.caption}`. A 6px `{colors.semantic-success}` dot when the SSE stream is live; `{colors.ink-tertiary}` dot when idle.

### Filter Tabs

**`filter-tab-default`** + **`filter-tab-selected`** — Pill-toggle row: All / MOCK / ERROR / MITM / TUNNEL.
- Default: `{colors.canvas}` background, `{colors.ink-subtle}` text, rounded `{rounded.pill}`, padding 6px 14px.
- Selected: `{colors.surface-2}` background, `{colors.ink}` text — selected = surface lift, with a 1px `{colors.primary}` ring.
- Hover on default lifts to `{colors.surface-1}`.

### Inputs & Forms

**`session-picker`** — `<select>` for switching between the live session and history.
- Background `{colors.surface-1}`, text `{colors.ink}`, type `{typography.body}`, rounded `{rounded.md}`, padding 8px 12px, 1px `{colors.hairline}` border.
- Focused state retains the same surface; the focus ring is a 2px `{colors.primary-focus}` outline at 50% opacity.

### Timeline

**`timeline-marker`** — 10px dot centered on the rail, one per node, color-coded by node type:
- Action → `{colors.primary}` · Evidence (before/after) → `{colors.semantic-success}` · Diff → `{colors.semantic-warning}` · Network → `{colors.semantic-network}` · Runtime advisory → `{colors.semantic-danger}`.
- Each marker carries a `0 0 0 4px` ring of its own color at 10% opacity.

**`lane-label`** — "UI EVIDENCE" / "NETWORK REQUESTS" column headers.
- Text `{colors.ink-subtle}`, type `{typography.eyebrow}`, uppercase, on raw canvas.

### Cards & Containers

**`evidence-card`** — Action node: action title, selector facts, copyable selector chips.
- Background `{colors.surface-1}`, text `{colors.ink}`, type `{typography.body}`, rounded `{rounded.lg}`, padding 24px, 1px `{colors.hairline}` border. Title in `{typography.card-title}`; timestamp right-aligned in `{typography.caption}` `{colors.ink-tertiary}`.

**`screenshot-panel`** — Before/after screenshot frame; the dominant card type — frames a high-fidelity device capture.
- Background `{colors.surface-1}`, text `{colors.ink}`, type `{typography.body}`, rounded `{rounded.xl}`, padding 24px, 1px `{colors.hairline}` border. Caption below the image in `{typography.caption}` `{colors.ink-subtle}`. Click opens the `lightbox`; hover lifts the border to `{colors.hairline-strong}`.

**`network-card`** — Request/response node: method + host title, status badge, headers, lazy body previews.
- Background `{colors.surface-1}`, rounded `{rounded.lg}`, padding 24px. URL in `{typography.mono}` `{colors.ink-muted}`, wrapped, never truncated silently. Nested body previews sit on `{colors.surface-4}` with `{rounded.md}` corners and `{typography.mono}`.

**`runtime-card`** — Runtime advisory node: pid / state-change facts.
- Same anatomy as `network-card`; identified by its `{colors.semantic-danger}` marker, not by a red fill.

**`empty-state`** — "No events yet" placeholder.
- Background `{colors.surface-1}`, text `{colors.ink-subtle}`, type `{typography.body}` with a `{typography.display-md}` hero line, rounded `{rounded.lg}`, padding 48px, centered.

### Data Display

**`facts-cell`** — Key/value stat cell, 3-up grid inside cards.
- Background `{colors.surface-2}`, rounded `{rounded.md}`, padding 8px 12px. Key in `{typography.eyebrow}` `{colors.ink-subtle}`; value in `{typography.mono}` `{colors.ink-muted}` when machine-valued, `{typography.body-sm}` otherwise.

**`diff-row`** — Each signal-ranked change row in the diff node, in the changelog-row idiom.
- Background `{colors.canvas}`, text `{colors.ink-muted}`, type `{typography.mono}`, rounded `{rounded.xs}`, padding 12px 0, 1px `{colors.hairline}` bottom rule. High-signal rows get a 2px `{colors.semantic-warning}` left rule — never a full amber background.

**`copy-chip`** — Click-to-copy chip for selectors, rule ids, value ids.
- Background `{colors.surface-2}`, text `{colors.ink-muted}`, type `{typography.mono}`, rounded `{rounded.sm}`, padding 2px 8px, 1px `{colors.hairline-strong}` border. Hover: text lifts to `{colors.ink}`, border to `{colors.primary-hover}`. On copy: a transient "Copied" state in `{colors.semantic-success}` for ~1.2s, then reverts.

**`status-badge`** — Small status pill on network cards: HTTP / HTTPS MITM / CONNECT tunnel / MOCK / ERROR.
- Background `{colors.surface-2}`, text `{colors.ink-muted}`, type `{typography.caption}`, rounded `{rounded.pill}`, padding 2px 8px. Text color carries the semantics: MOCK → `{colors.semantic-success}`, ERROR → `{colors.semantic-danger}`, MITM/TUNNEL → `{colors.semantic-network}`. Background stays neutral in every case.

### Overlay

**`lightbox`** — Full-screen screenshot viewer.
- Scrim: `{colors.semantic-overlay}` at 70% opacity. Dialog: image at native ratio in a `{rounded.xl}` frame with the single permitted shadow (`0 24px 80px rgba(0,0,0,.45)`); caption below in `{typography.caption}` `{colors.ink-subtle}`. Escape and backdrop-click close it.

## Do's and Don'ts

### Do

- Reserve `{colors.canvas}` (#010102) as the system's anchor surface — the faint blue tint is intentional.
- Use `{colors.primary}` lavender ONLY for: selected filter ring, focus rings, links, action markers.
- Use the four-step surface ladder for hierarchy. Avoid skipping levels.
- Pair display weight 600 with body weight 400 — resist 700+ weights everywhere.
- Apply negative letter-spacing on display sizes.
- Use evidence screenshots as the protagonist of every action trace.
- Border every lifted surface with a 1px hairline; let borders, not shadows, do the separation.
- Render every copyable machine fact (selector, URL, id, diff value) in mono inside a `copy-chip` or mono cell.
- Keep semantic color on markers, badge text, and thin rules — dots and edges, never fills.

### Don't

- Don't ship a light mode.
- Don't use lavender as a section background or card fill.
- Don't introduce a second chromatic accent on chrome — semantic hues live only on markers, badges, and signal rules.
- Don't add atmospheric gradients or spotlight cards.
- Don't pill-round cards or primary controls.
- Don't use `#000000` true black as the canvas.
- Don't put drop shadows on cards — the lightbox dialog is the sole exception.
- Don't fill a card, row, or section with a semantic color.
- Don't truncate URLs, selectors, or ids without a copy affordance for the full value.

## Responsive Behavior

### Breakpoints

| Name | Width | Key Changes |
|---|---|---|
| Desktop-XL | 1440px | Default desktop layout |
| Desktop | 1280px | Two-lane timeline maintained, 3-up facts grids |
| Tablet | 1024px | Facts grids 3-up → 2-up |
| Mobile-Lg | 768px | Timeline collapses to a single column; rail moves to the left edge |
| Mobile | 480px | Single-column; facts grids 1-up; filter tabs scroll horizontally; display-md scales 40px → ~28px |

### Touch Targets

- Filter tab pills hold ≥36px tap height; touch viewports grow to ≥44px.
- Copy chips hold ≥36px effective tap height on touch viewports (padding grows, type does not).
- The session picker holds ≥44px tap target on touch.

### Collapsing Strategy

- **Two lanes → one column** below 768px: nodes interleave chronologically; each card keeps its type marker and gains an eyebrow type label.
- **Top nav**: wraps to two rows (title + status / filters + picker) below 768px.
- **Facts grids**: 3-up → 2-up at 1024px → 1-up below 480px.
- **Network body previews** stay collapsed by default below 768px; expand on tap.
- **Display type**: `{typography.display-md}` 40px scales toward `{typography.headline}` 28px on mobile.

### Image Behavior

- Evidence screenshots maintain aspect ratio and never crop; portrait captures max out at ~70vh inside the lightbox.
- Never upscale a capture past its native resolution.
- The lightbox goes edge-to-edge below 480px with a persistent close button.

## Iteration Guide

1. Focus on ONE component at a time and reference it by its `components:` token name.
2. When introducing a new surface, decide first which surface lift it lives on — if it needs a new background value, the answer is a ladder step, not a new color.
3. Default body to `{typography.body}` at weight 400.
4. New node types on the timeline get: a marker color from the existing semantic set, a `{rounded.lg}` surface-1 card, and an eyebrow type label — in that order.
5. Treat lavender as scarce: selection, focus, links, action markers — nothing else.
6. Lead every action trace with an evidence screenshot.
7. Every token in this file maps 1:1 to a CSS custom property in the `:root` block of `reticle-host/Sources/ReticleHostCore/WebPanel.swift` (`--canvas`, `--surface-1`, `--ink`, `--primary`, …). Update the CSS variables and this file together; never hard-code a hex in a component rule.
8. The panel stays **display-only** (see `docs/roadmap.md`, Phase 3): no mutating controls, so no primary-button spec exists — do not add one without revisiting the roadmap.
9. Add new variants as separate component entries.
10. Run `npx @google/design.md lint DESIGN.md` after edits.

## Known Gaps

- The surface-ladder and hairline values are adopted from the Linear dark-surface spec (`#010102` / `#0f1011` / `#141516` / `#18191a` / `#23252a` …); they may be tuned once real evidence screenshots (often bright, light-mode app captures) are evaluated against the darker canvas.
- Light mode is not documented — the panel is a developer tool and ships dark-only.
- The reference system's custom display, text, and mono families are proprietary; **Inter** and **JetBrains Mono** are the documented open substitutes, with the SF Pro stack as the macOS fallback.
- Error/validation styling for the session picker (e.g. a session that fails to load) is unspecified beyond the status line.
- Print/export styling for evidence reports is out of scope for this version.
- The panel has no primary action button by design (read-only surface); if Phase 3+ adds interactions, a `button-primary` spec in the reference idiom (lavender fill, `{rounded.md}` 8px corners, 8px 14px padding) should be added here first.
