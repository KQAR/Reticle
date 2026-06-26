# Helper RPC contract

The contract between a **non-JVM host** (the Swift host) and the **Kotlin Android
helper** (`reticle helper`). The helper is today's Android host layer (adb + JDWP
injector + input) kept in Kotlin and driven across a process boundary; see
`docs/roadmap.md` → "Direction: Swift host + per-platform helpers".

This lives in `reticle-protocol/` because it is a cross-language contract, exactly
like the wire protocol (`snapshot.schema.json`). The payloads that carry UI trees
(`snapshot` / `semantics` / `compact`) are the same shapes that schema defines.

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

| Method | Params | Result |
| --- | --- | --- |
| `ping` | — | `{ "pong": true, "version": "<cli version>" }` |
| `listDevices` | — | `{ "devices": [ { "serial", "state" }, ... ] }` |
| `status` | `package?`, `serial?`, `port?`, `hostPort?` | `{ "devices": [...], ["package", "running", "pid", "runtime"] }` — `runtime` ∈ `healthy`/`conflict`/`unreachable`/`unresponsive`/`foreign` |
| `inject` | `package` (req), `serial?`, `payloadDex?`, `port?`, `hostPort?` | `{ "pid", "packageName", "port", "agentVersion", "reportedPort" }` |
| `uiReport` | `package` (req), `serial?`, `port?`, `hostPort?` | `{ "nodeCount", "compactItemCount", "semanticNodeCount", "snapshot": <Snapshot>, "semantics": <SemanticTree>, "compact": <CompactObservation> }` |

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
- **`uiReport` returns finished trees.** The derivation (`SemanticTree.build`,
  `CompactObservation.from`) runs in the helper, device-side; the host just writes
  the returned JSON to `snapshot.json` / `semantics.json` / `compact.json`. The
  host never re-derives. This is the "thin client" boundary in practice.

## Not yet covered (add as the host grows)

`act` (tap/swipe/drag/type), `mutate`, `debug logs`, `screenshot` (binary — needs
a base64 field or a side channel), and `app launch`. Add each as a method here +
the matching `Helper.dispatch` branch when the Swift host needs it.
