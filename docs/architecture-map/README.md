# Architecture map

Two views of the same document, for two kinds of reader.

| File | For | What it is |
| --- | --- | --- |
| [`index.html`](index.html) | people | A self-contained dark-theme page: an interactive architecture diagram plus an interactive Flows section that highlights a path and steps through it. Open it directly — no server, no build. Tailwind comes from a CDN; everything else is inline. |
| [`map.json`](map.json) | AI agents / tooling | `{ meta, nodes, edges, edgeKinds, flows: [{ steps }] }`. The machine-readable form: 18 nodes, 27 edges, 10 flows, 56 steps. |

**They cannot disagree — and now something checks.** `index.html` renders
entirely from a verbatim copy of `map.json` embedded in a
`<script type="application/json">` block, and the page's Download button hands
back those same bytes. That copy used to be resynced by hand, which is to say
sometimes: measured before this was automated, the embedded map was missing a
whole flow step and still claimed version 0.11.0 while the repo was on 0.12.0, so
a person reading the page and an agent reading the JSON were told different
things about the same system.

Edit `map.json`, then:

```bash
python3 scripts/validate_architecture_map.py --fix   # rewrite the embedded copy
python3 scripts/validate_architecture_map.py         # what CI runs
```

The check is a CI gate. Besides the two copies agreeing, it asserts
`meta.version` matches the repo-root `VERSION`, that every edge endpoint and
every id a flow step cites resolves to a real node or edge (a typo'd id renders
as a step that highlights nothing), and that every fixture and module path the
map names actually exists.

## Reading the page

- **Click a box** — the inspector shows what the module is, its in/out edges by
  kind, and which flows it appears in. Unrelated boxes dim; neighbours stay lit.
- **Pick a flow** — the diagram dims to just that path, and the stepper walks it.
  `←` / `→` to step, `Esc` to clear. Each step names the nodes and edge kinds it
  touches.
- **Layer chips** (host / shared / wire / device / external) mute a whole layer.
- **Deep links** — the URL carries the view, so a specific step is shareable:
  `index.html#flow=app-inject&step=3`, `index.html#node=helper`.

## What the model encodes

`meta.invariants` is the part worth reading first — the seven statements every
other box and arrow is commentary on (the agent observes but never synthesizes
input; the port is derived, not fixed; `reticle serve` owns all session state;
Android goes out through a helper while iOS is handled in-host; every projection
is a pure function of one `Snapshot`; each derivation exists exactly twice and is
pinned by shared fixtures; an unreachable thing must produce evidence naming
itself).

Nodes carry `layer` (which band) and `kind` (what sort of artifact) plus their
diagram geometry, so the layout lives in the data rather than in the renderer.
Edges carry a `kind` from `edgeKinds` — `depends`, `owns`, `rpc`, `drives`,
`http`, `input`, `serves`, `injects`, `pins`, `proxies` — which is what makes
"compile-time dependency" and "synthesized real input" distinguishable rather
than both being a line.

Every flow step references node and edge **ids**, so the JSON is directly
consumable: an agent can answer "what does `app inject` touch, in order" without
parsing prose.

## Provenance

Derived from `AGENTS.md`, `docs/architecture.md`, `docs/boundaries.md` and
`docs/ios.md`. Those remain the source of truth — this is a projection over them,
and the same rule applies here as everywhere else in the repo: if the map and the
prose disagree, the prose wins and the map is stale. `docs/architecture.md` is
still the place to read *why*; this is the place to see the shape and trace a
path.
