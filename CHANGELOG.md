# Changelog

## Unreleased

- Slimmed the wire payload: `ReticleJson` now omits null and default-valued
  fields (`encodeDefaults=false`, `explicitNulls=false`, schema-required
  defaults pinned with `@EncodeDefault(ALWAYS)`), the agent serves HTTP
  responses with the compact (non-pretty) instance, and the `MetadataValue`
  `_type` discriminator uses short tags (`text`/`bool`/`int`/`real`) instead of
  fully-qualified Kotlin class names. Lossless; ~60% smaller snapshot responses.
- Fixed `SemanticTree.build` producing a dangling root and child refs: the tree
  now synthesizes a resolvable root, reparents kept nodes across dropped
  containers, and guarantees every node is reachable from the root.
- Unified the "targeting signal" test behind `Node.hasTargetingSignal()` so the
  semantic tree and compact observation can no longer disagree about which nodes
  are targetable.
- Hardened `input text` shell quoting to single-quote wrapping so typed text
  can no longer be interpreted by the device shell (`$(…)`, backticks).
- Made the daemon event store tolerate a corrupt or partially-written trailing
  JSONL line instead of failing to load the whole session.

Validation:

- reticle-core, Android helper, and Swift host tests.
- Plugin manifest/version-lockstep validation.
- GitHub CI for all optimization pull requests.

## 0.6.5 - 2026-07-03

- Added structured JSON result envelopes for host commands, including `--json`
  output on supported user-facing commands.
- Added selector-miss diagnostics with same-kind candidates from the current
  snapshot.
- Added `reticle ui outline`, short-lived `@N` aliases, and `reticle act
  --alias` for faster agent-driven targeting.
- Added a `reticle serve` helper broker so commands can reuse the daemon-hosted
  helper through `--use-daemon` or `RETICLE_USE_DAEMON=1`.
- Added runtime process advisories, persisted process-state, and matching
  serve-panel cues.
- Added repeated-item ordinal hints to UI outlines and alias cache entries.
- Added `reticle act batch` for ordered action sequences from a JSON file.

Validation:

- Swift host tests.
- Android helper tests.
- Plugin manifest/version-lockstep validation.
- GitHub CI for all optimization pull requests.
