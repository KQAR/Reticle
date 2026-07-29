# Helper RPC contract

The contract between a **non-JVM host** (the Swift host) and the **Kotlin Android
helper** (`reticle helper`). The helper is today's Android host layer (adb + JDWP
injector + input) kept in Kotlin and driven across a process boundary; see
`docs/roadmap.md` → Decisions of record, "Swift host + per-platform helpers".

This lives in `reticle-protocol/` because it is a cross-language contract, exactly
like the wire protocol (`snapshot.schema.json`). The payloads that carry UI trees
(`snapshot` / `semantics` / `compact`) are the same shapes that schema defines.

The daemon event bus is a separate contract: `reticle serve` exposes localhost
REST/SSE and persists `events.jsonl` session timelines. See `events.md` for that
surface. When `serve --helper-broker` is enabled, the daemon also exposes a
thin HTTP wrapper around this same helper RPC; that wrapper does not add helper
methods or change the JSONL stdio contract below.

The helper ships as the no-JDK native `reticle-helper` (GraalVM native-image).
**Build note:** the helper talks to the in-app loopback server over HTTP
(`java.net.URL`), and native-image disables URL protocols by default — the build
must pass `--enable-url-protocols=http` or every device call fails with "URL
protocol http … not enabled" (the `:reticle-helper:nativeHelper` task does this).

## Where this contract sits in the host

The Swift host does **not** call these method names from its command code. It calls
the typed `HostBackend` interface (one method per capability), and `AndroidBackend`
is the single adapter that turns a typed request into the envelope below and the
reply back into a typed result. So this document describes one backend's transport,
not the host's internal interface — a distinction worth keeping, because the iOS
backend implements the same capabilities with no wire at all, and used to have to
speak this one to be callable.

## Transport

- The host spawns `reticle helper` **once** and keeps it alive for the session
  (it is a resident RPC service, not fork-per-call — high-frequency calls like
  forward/screencap/input must not pay process-startup cost).
- **Framing: newline-delimited JSON (JSONL).** One request object per line on the
  helper's stdin; one response object per line on its stdout.
- **stdout is protocol-only.** All diagnostics go to stderr. The host can parse
  stdout as a clean JSONL stream.
- Closing the helper's stdin ends its loop (clean shutdown).
- **Default hot path: the per-device helper daemon.** One-shot commands connect
  to `~/.reticle/helperd/<serial|default>.sock` (a Unix-domain socket carrying
  this same JSONL envelope, one frame per line), fork-execing
  `reticle helper-daemon` on first use and waiting ≤5s for the socket. The
  daemon keeps one resident helper alive, answers two control methods itself —
  `helperd/info` (version + helper path/mtime, used to restart a stale daemon
  after a CLI upgrade or helper rebuild) and `helperd/shutdown` — and exits
  after 600s idle (override: `RETICLE_HELPERD_IDLE`), unlinking its socket.
  Opt out with `--no-daemon` / `RETICLE_NO_DAEMON=1`; any bring-up failure
  falls back to a command-owned helper spawn.
- The Swift daemon can also broker the same calls through `POST /helper/rpc`
  when `reticle serve --helper-broker` is enabled; one-shot commands opt in
  with `--use-daemon` or `RETICLE_USE_DAEMON=1` (this takes precedence over
  the socket hot path). The broker forwards ONLY the methods in the table below
  — it is the one place a caller-supplied string reaches the helper process, so
  anything else is refused with a 400 naming it rather than handed on. The Swift
  side of that gate is `HelperMethod`, which a contract test checks against this
  very table.

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
- Selector misses are returned as ordinary `ok: false` responses, but the
  `error` string includes same-kind candidates from the current snapshot when
  available (test ids, resource ids, DOM CSS selectors, or refs).

The user-facing Swift host also exposes a CLI-level `--json` mode for
helper-backed commands. That mode is a separate stdout envelope designed for
scripts and agents: success is `{ "ok": true, "data": ... }`, failure is
`{ "ok": false, "error": ... }`. It wraps the helper result after the RPC call;
it does not change this helper stdio contract.

## Methods

Common optional params on device methods: `serial`, `port`, `hostPort`. Selector
params (where noted): `testId`, `resourceId`, `css` (WebView DOM selector),
`ref`, `point` ("x,y"), `region`, `alias` (`@N` from the last outline cache).
An `alias` is re-resolved against the live tree before use (matched by the
cached entry's selector, then label+role, nearest-to-cached-frame on ties) so a
relayout between `ui outline` and `act` does not land on stale coordinates; the
cached frame is only used when the runtime is unreachable, and the result's
`source` says which path was taken (`outline:@N->live` vs cached frame).

| Method | Params | Result |
| --- | --- | --- |
| `ping` | — | `{ "pong": true, "version": "<cli version>" }` |
| `listDevices` | — | `{ "devices": [ { "serial", "state" }, ... ] }` |
| `status` | `package?` | `{ "devices": [...], ["package", "running", "pid", "runtime"] }` — `runtime` ∈ `healthy`/`conflict`/`unreachable`/`unresponsive`/`foreign` |
| `inject` | `package` (req), `payloadDex?`, `restartUnderDebugger?` (mark the app as being debugged so AMS relaxes the input-dispatch ANR during the JDWP suspension — **force-stops and relaunches the target**, so it is opt-in) | `{ "pid", "packageName", "port", "agentVersion", "reportedPort" }` |
| `launch` | `package` (req) | `{ "pid", "packageName", "port", "agentVersion" }` — monkey-launches a LINKED app and waits for its runtime |
| `uiReport` | `package` (req) | `{ "nodeCount", "compactItemCount", "semanticNodeCount", "snapshot": <Snapshot>, "semantics": <SemanticTree>, "compact": <CompactObservation> }` |
| `act` | `gesture` (tap/swipe/drag/type/hide-keyboard), `package` (req); tap: selector or `alias`; a selector tap re-resolves its point before dispatch **by default** (800ms budget) so a rect made stale by an earlier relayout cannot land the touch on the neighbour — `settle?` raises the budget to 2s for a target that is animating in, `settleTimeoutMs?` overrides either, `noSettle?` opts out, and a raw `point` never confirms (`settle` with `point` is refused); swipe/drag: `from`,`to`,`duration?`; type: `text`, `submit?` (perform the focused field's IME editor action after typing — agent `/editor-action` preferred, `KEYCODE_ENTER` fallback); optional `verify`, `verifyTimeoutMs`, `traceOutput`, `traceDelayMs` | `{ "gesture", ... }`, optionally `verify` and `trace` summaries; a confirming tap adds `"settled": bool` (false = still moving when the budget lapsed, so the point may already be stale) and, only when the re-resolve moved the point, `"rectMoved": "<dx>,<dy>"` — the evidence that the first read WAS stale; type with `submit` adds `"submit": { "via", "action?" }`. Host `act batch --file` expands a JSON array into repeated `act` RPC calls; it is not a separate helper method — step keys are these protocol field names (so `resourceId`, `ref`, `point`, `alias`, `region` all work in steps). |
| `mutate` | `package` (req), `property`, `value`, selector | `{ "applied", "ref", "previousValue" }` |
| `logs` | `package` (req) | `{ "entries": [ { "level", "message" }, ... ] }` (app-authored runtime logs) |
| `logcat` | `serial?` | `{ "lines": [ "<agent logcat>", ... ] }` (process-wide; works without a runtime) |
| `screenshot` | `package?` | `{ "via", "pngBase64" }` — agent `/screenshot` if reachable, else `adb screencap` |
| `render` | `view` (tree/semantics/compact/outline/node/regions), `snapshot` (path), `depth?`, `window?` (a window ref or `top` — narrows the SNAPSHOT before rendering, so every view and the `@N` numbering scope together; an unknown ref is an error naming the windows that exist), selector, optional `package` to write outline alias cache | `{ "text": "<rendered>" }` — local snapshot rendering; `outline` adds `item i/n` hints for repeated vertical targets and writes those hints into the alias cache. With more than one window in the capture, `compact` and `outline` group their lines under a `window <ref> … [top]` header per window, topmost first |
| `proxyStatus` | `serial?` | `{ "httpProxy": "<host:port>" }` or empty when unset |
| `proxySet` | `serial?`, either `host` + `port` or raw `value` | `{ "previous", "current" }` — configures Android global `http_proxy`; `127.0.0.1:<port>` also creates `adb reverse tcp:<port> tcp:<port>` |
| `proxyClear` | `serial?`, `port?` | `{ "previous", "current": "" }` — clears Android global `http_proxy` and removes the matching adb reverse when `port` is supplied |
| `proxyInstallCa` | `serial?`, `path`, `name?` | `{ "path", "name", "started", "message" }` — pushes a DER CA certificate to device Downloads and opens Android Security settings for user-confirmed installation |

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
- **`proxySet` is host-owned device configuration.** The helper only applies the
  Android setting and optional `adb reverse`; it does not inspect traffic. The
  Swift daemon owns the actual proxy listener and restores the prior value on
  shutdown.
- **`proxyInstallCa` cannot silently trust a CA.** Android 11+ requires CA
  certificates to be installed from Settings by the user. The helper only pushes
  the file and opens the official security settings screen.

## Coverage

The Swift host (`reticle-host/`) now reaches functional parity with the Kotlin
CLI's one-shot command surface through these methods: device control
(status/inject/launch), evidence (uiReport/render/screenshot/logs/logcat), and
action (act/mutate). Binary screenshots cross as base64 (`pngBase64`).

Not yet exposed (add a method + a `Helper.dispatch` branch when needed): a
streaming/long-poll `logs --follow`, and any future `act` gestures beyond
tap/swipe/drag/type (e.g. multi-touch pinch, still unimplemented in the backend).
