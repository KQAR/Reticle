# reticle-protocol

The **authoritative, language-neutral wire contract** for Reticle. This is the
cross-platform spine: it defines the JSON every Reticle agent emits and every
host CLI consumes, independent of implementation language.

This directory is **not a build module**. It holds spec files and fixtures; each
platform implementation references them however its toolchain prefers.

```
reticle-protocol/
├─ schema/      # JSON Schema (2020-12) — the source of truth for the wire shape
└─ fixtures/    # golden payloads every implementation must reproduce/consume
```

## Authority model

- The **JSON Schema is authoritative.** When the schema and any implementation
  disagree, the implementation is wrong.
- **Kotlin (`reticle-core`) is hand-written and verified**, not generated. Its
  types keep their doc comments and the kotlinx-serialization setup for sealed
  hierarchies (e.g. `MetadataValue`) that codegen handles poorly. A CI contract
  test (`ProtocolContractTest` in `reticle-core`) pins three directions:
  1. the golden fixture validates against the schema,
  2. JSON emitted by the Kotlin model validates against the schema,
  3. the golden fixture deserializes back through Kotlin losslessly.
- **Future greenfield platforms (Swift / ArkTS) may codegen** their models from
  the same schema. "Generate vs hand-write" is each platform's choice; the schema
  is the contract everyone shares.

## Serialization conventions encoded in the schema

These are not incidental — implementations must match them exactly:

- `encodeDefaults = true`: every field is emitted, including defaults; nullable
  fields appear explicitly as JSON `null`.
- The sealed `MetadataValue` is discriminated by a **`_type`** property whose
  value is the fully-qualified Kotlin class name (e.g.
  `dev.reticle.core.MetadataValue.Real`). A non-Kotlin implementation must emit
  these exact discriminator strings to stay wire-compatible. (If this coupling to
  Kotlin class names ever becomes a burden for another platform, the fix is to
  add `@SerialName` aliases in `reticle-core` and update the schema enum + this
  note in lockstep — not to diverge silently.)
- `Long` → JSON integer; `Double` → JSON number.

## Current coverage

- `schema/snapshot.schema.json` — the `Snapshot` view-tree payload and every
  nested type (`Node`, `ScreenInfo`, `Rect`, `MetadataValue`, `InteractionRegion`,
  `CharGrid`, `NodeKind.domNode`, …). This is the primary capture payload.

Not yet schematized (tracked for later, as the roadmap phases reach them):
`UiReport`, `SemanticTree`, `CompactObservation`, the `Protocol`
request/response envelopes, and action/session event envelopes. Add each with a
golden fixture and extend the contract test when the corresponding feature lands.
