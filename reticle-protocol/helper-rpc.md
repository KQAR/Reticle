# Helper RPC contract

The contract between a **non-JVM host** (the Swift host) and the **Kotlin Android
helper** (`reticle helper`). The helper is today's Android host layer (adb + JDWP
injector + input) kept in Kotlin and driven across a process boundary; see
`docs/roadmap.md` → "Direction: Swift host + per-platform helpers".

This lives in `reticle-protocol/` because it is a cross-language contract, exactly
like the wire protocol (`snapshot.schema.json`). The payloads that carry UI trees
(`snapshot` / `semantics` / `compact`) are the same shapes that schema defines.

The helper ships as the no-JDK native `reticle-helper` (GraalVM native-image).
**Build note:** the helper talks to the in-app loopback server over HTTP
(`java.net.URL`), and native-image disables URL protocols by default — the build
must pass `--enable-url-protocols=http` or every device call fails with "URL
protocol http … not enabled" (the `:reticle-helper:nativeHelper` task does this).

## Transport

- The host spawns `reticle helper` **once** and keeps it alive for the session
  (it is a resident RPC service, not fork-per-call — high-frequency calls like
  forward/screencap/input must not pay process-startup cost).
- **Framing: newline-delimited JSON (JSONL).** One request object per line on the
  helper's stdin; one response object per line on its stdout.
- **stdout is protocol-only.** All diagnostics go to stderr. The host can parse
  stdout as a clean JSONL stream.
- Closing the helper's stdin ends its loop (clean shutdown).

## Envelope

Request:

```json
{ "id": 1, "method": "inject", "params": { "package": "com.example.app" } }
```

Response (success):

```json
{ "id": 1, "ok": true, "result": { ... } }
```

Response (failure):

```json
{ "id": 1, "ok": false, "error": "human-readable message" }
```

- `id` is an integer the host chooses; the helper echoes it so responses can be
  correlated. A malformed request line is answered with `id: -1`.
- An unknown method, missing params, or any thrown error becomes an `ok: false`
  response — **the loop never dies on a bad call** (verified: a bad call between
  two good ones does not disturb them).

## Methods

Common optional params on device methods: `serial`, `port`, `hostPort`. Selector
params (where noted): `testId`, `resourceId`, `css` (WebView DOM selector),
`ref`, `point` ("x,y"), `region`.

| Method | Params | Result |
| --- | --- | --- |
| `ping` | — | `{ "pong": true, "version": "<cli version>" }` |
| `listDevices` | — | `{ "devices": [ { "serial", "state" }, ... ] }` |
| `status` | `package?` | `{ "devices": [...], ["package", "running", "pid", "runtime"] }` — `runtime` ∈ `healthy`/`conflict`/`unreachable`/`unresponsive`/`foreign` |
| `inject` | `package` (req), `payloadDex?` | `{ "pid", "packageName", "port", "agentVersion", "reportedPort" }` |
| `launch` | `package` (req) | `{ "pid", "packageName", "port", "agentVersion" }` — monkey-launches a LINKED app and waits for its runtime |
| `uiReport` | `package` (req) | `{ "nodeCount", "compactItemCount", "semanticNodeCount", "snapshot": <Snapshot>, "semantics": <SemanticTree>, "compact": <CompactObservation> }` |
| `act` | `gesture` (tap/swipe/drag/type), `package` (req); tap: selector; swipe/drag: `from`,`to`,`duration?`; type: `text`; optional `verify`, `verifyTimeoutMs`, `traceOutput`, `traceDelayMs` | `{ "gesture", ... }`, optionally `verify` and `trace` summaries |
| `mutate` | `package` (req), `property`, `value`, selector | `{ "applied", "ref", "previousValue" }` |
| `logs` | `package` (req) | `{ "entries": [ { "level", "message" }, ... ] }` (app-authored runtime logs) |
| `logcat` | `serial?` | `{ "lines": [ "<agent logcat>", ... ] }` (process-wide; works without a runtime) |
| `screenshot` | `package?` | `{ "via", "pngBase64" }` — agent `/screenshot` if reachable, else `adb screencap` |
| `render` | `view` (tree/semantics/compact/node/regions), `snapshot` (path), `depth?`, selector | `{ "text": "<rendered>" }` — local snapshot rendering; derivation stays in Kotlin, host just prints |

### Notes that bit us in the spike

- **`payloadDex` must be explicit.** The helper resolves the injectable dex
  cwd-relative by default, which breaks when the host spawns it from another
  directory. Pass `payloadDex` (an absolute path) on `inject`; the helper applies
  it via the `reticle.payloadDex` system property, which
  `Injector.locatePayloadDex` honors first. (Env `RETICLE_PAYLOAD_DEX` also works
  but a spawned child may not inherit the intended value.)
- **`inject` waits for liveness.** It does not return when the JDWP invoke
  finishes — it forwards a port and polls `/runtime` until the agent answers
  healthy (or times out with a clear error). So a successful `inject` result means
  the runtime is actually up.
- **`uiReport` returns finished trees.** Current agents capture one `/report` and
  derive `SemanticTree` / `CompactObservation` from that exact snapshot; the
  helper forwards the finished JSON and the host writes it to `snapshot.json` /
  `semantics.json` / `compact.json`.
- **`act.traceOutput` writes an evidence package.** When present, the helper
  captures before/after snapshots and screenshots around the action, writes them
  under `<traceOutput>/<actionId>/`, and returns a small `trace` summary with the
  manifest path. The on-disk manifest is `trace.json` and uses the
  `dev.reticle.core.trace.ActionTrace` shape from `reticle-core`; large artifacts
  are referenced by relative filename instead of being inlined in the RPC
  response.

## Coverage

The Swift host (`reticle-host/`) now reaches functional parity with the Kotlin
CLI's one-shot command surface through these methods: device control
(status/inject/launch), evidence (uiReport/render/screenshot/logs/logcat), and
action (act/mutate). Binary screenshots cross as base64 (`pngBase64`).

Not yet exposed (add a method + a `Helper.dispatch` branch when needed): a
streaming/long-poll `logs --follow`, and any future `act` gestures beyond
tap/swipe/drag/type (e.g. multi-touch pinch, still unimplemented in the backend).
