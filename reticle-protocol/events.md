# Reticle daemon event protocol

`reticle serve` owns the local session timeline. It exposes a lightweight
localhost REST/SSE surface, currently served by the Swift host through
Hummingbird 2.25.0, and persists every accepted event to:

```text
~/.reticle/sessions/<session>/events.jsonl
```

This protocol is intentionally separate from `helper-rpc.md`: the helper remains
the Android device layer over JSONL stdio, while the daemon is the user-facing
session/event surface.

## Event envelope

Every line in `events.jsonl` is one JSON object:

```json
{
  "schemaVersion": 1,
  "id": "evt_0000000000000001",
  "ts": 1782751906383,
  "session": "reticle-e2e",
  "target": "android:dev.reticle.sample",
  "source": "action",
  "type": "action.trace",
  "payload": {},
  "refs": {}
}
```

- `schemaVersion` is the envelope generation (currently `1`). It is bumped only
  on a **breaking** envelope-shape change — a top-level field renamed, removed,
  or retyped. Additive fields do not bump it. Per-payload shapes carry their own
  independent versions (e.g. `payload.traceVersion`). A consumer should read
  `schemaVersion` to decide whether it understands the envelope; lines written
  before this field existed are read as generation `1`.
- `id` is daemon-assigned, sortable, and monotonically increasing within a
  session.
- `ts` is epoch milliseconds stamped by the daemon.
- `session` is the session directory name.
- `target` identifies the app/device scope when known.
- `source` groups producers such as `action`, `ui`, `runtime`, `log`, or future
  `proxy`.
- `type` is a concrete event kind such as `action.trace`.
- `payload` is type-specific JSON.
- `refs` points at large local artifacts, such as snapshots and screenshots.

## REST/SSE surface

The skeleton serves these endpoints on `127.0.0.1`:

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/health` | Current daemon health, session, port, and retained event count. |
| `GET` | `/panel` | Built-in read-only web panel for the current session timeline. |
| `GET` | `/sessions` | Session history listing with event/action counts, update time, and current marker. |
| `GET` | `/sessions/current/events?since=<id>` | Buffered event history after `id`; omit `since` for all retained events. |
| `GET` | `/sessions/{id}/events?since=<id>` | Static history for a persisted session id. |
| `GET` | `/sessions/current/artifacts?event=<id>&ref=<name>` | Reads one local artifact path from that event's `refs`; there is no raw path parameter. |
| `GET` | `/sessions/{id}/artifacts?event=<id>&ref=<name>` | Reads an artifact through a historical session event ref. |
| `POST` | `/sessions/current/events` | Append a daemon-stamped event body, including proxy-produced `network.*` events. |
| `POST` | `/sessions/current/action-traces` | Ingest an existing action `trace.json` or `{ "path": "/.../trace.json" }`. |
| `GET` | `/sessions/current/rules/export` | Export rules plus value bodies as a JSON package. |
| `POST` | `/sessions/current/rules/import` | Import a rule JSON package into the current session. |
| `POST` | `/sessions/current/rules/clear` | Remove all current-session rules, values, and value body files. |
| `POST` | `/sessions/current/rules/resolve` | Preview which rule (and mock value, if any) would match a method + absolute URL. |
| `GET` | `/sessions/current/rules` | List current-session traffic rules. |
| `POST` | `/sessions/current/rules` | Create or update a traffic rule (route: mock/block/mapRemote/passthrough + modifiers). |
| `POST` | `/sessions/current/rules/{id}/enable` | Enable a rule. |
| `POST` | `/sessions/current/rules/{id}/disable` | Disable a rule. |
| `DELETE` | `/sessions/current/rules/{id}` | Remove a rule. |
| `GET` | `/sessions/current/rules/values` | List current-session mock response values. |
| `POST` | `/sessions/current/rules/values` | Create or update a mock response value. |
| `DELETE` | `/sessions/current/rules/values/{id}` | Remove an unreferenced mock value. |
| `GET` | `/sessions/current/flows` | Find still-replayable flows by filter (`host`, `method`, `urlContains`, `status`/`statusMin`/`statusMax`, `onlyErrors`, `sinceMillis`, `limit`). Scoped to the capture engine's buffer, not the session's full evidence. |
| `POST` | `/sessions/current/flows/{id}/replay` | Re-send a captured flow with overrides; emits a `network.replay` event and returns the diff vs the original. |
| `POST` | `/helper/rpc` | Present only when `serve --helper-broker` is enabled; forwards one helper RPC through the daemon-owned helper process. |
| `GET` | `/events/stream?since=<id>` | Server-Sent Events replay followed by live events. |

SSE responses use `text/event-stream; charset=utf-8`, one event per frame:

```text
id: evt_0000000000000001
event: action.trace
data: {"id":"evt_0000000000000001",...}

```

## Action trace ingestion

`POST /sessions/current/action-traces` maps the existing `ActionTrace` manifest
into an `action.trace` event:

- `payload` keeps the manifest's small fields: `actionId`, `packageName`,
  `recordedAtMillis`, `gesture`, `selector`, `target`, `result`,
  `changeCount`, and `traceVersion`.
- `refs` contains absolute local paths for `manifest`, `beforeSnapshot`,
  `afterSnapshot`, and screenshots when present.

One-shot `reticle act ... --trace-output <dir>` keeps its existing behavior.
When a live daemon is discoverable through `~/.reticle/daemon.json`, `act`
automatically writes trace packages under
`~/.reticle/sessions/<session>/traces` and publishes them as `action.trace`
events on a best-effort basis. If runtime evidence is unavailable for an
auto-trace, the action still runs; explicit `--trace-output` remains strict.

## Runtime advisories

`reticle status --package <pkg>` stores the last observed app process/runtime
state in `~/.reticle/process-state.json`. If a later status sees the process
stop, the PID change, or the runtime move from `healthy` to an unhealthy state,
the CLI emits a warning and, when a daemon is running, publishes a
`runtime.advisory` event:

- `source`: `runtime`
- `type`: `runtime.advisory`
- `target`: `android:<package>`
- `payload.kind`: `process-stopped`, `process-restarted`, or
  `runtime-degraded`
- `payload.message`: human-readable advisory text
- `payload.previousPid`, `currentPid`, `previousRuntime`, `currentRuntime`:
  comparison details when available

## Helper broker

`reticle serve --helper-broker` starts one long-lived `reticle-helper` process
owned by the daemon and exposes `POST /helper/rpc` on the same localhost server.
One-shot commands opt into that path with `--use-daemon` or
`RETICLE_USE_DAEMON=1`; default commands still spawn their own helper and do not
require a daemon.

Request:

```json
{ "method": "status", "params": { "package": "dev.reticle.sample" } }
```

Response:

```json
{ "ok": true, "result": { "running": true } }
```

Helper errors stay in-band as `{ "ok": false, "error": "..." }`, matching the
underlying helper contract. The route exists only when the broker is enabled;
otherwise it returns 404. `--serial` on the one-shot command is forwarded in that
request and overrides the daemon broker's default serial for that call.

## Network proxy events

When `reticle serve --proxy-port <port>` is running, the host proxy emits
normalized network events into the same event stream:

- `source`: `proxy`
- `type`: `network.request`, `network.response`, `network.error`,
  `network.replay` (a re-sent flow plus its diff; see [Flow replay](#flow-replay)),
  `network.websocket` (one frame inside an upgraded socket; see
  [WebSocket frames](#websocket-frames)), or `network.advisory` (the capture lane
  reporting on its own fidelity; see [Capture advisories](#capture-advisories)).
- `payload.requestId`: stable id shared by the request/response/error events.
- `payload.method`, `url`, `scheme`, `host`, `port`, `path`: request target.
- `payload.startMillis`, `endMillis`, `durationMs`: request interval timing.
- `payload.firstByteMillis`, `ttfbMs`, `receiveMs`: when the response *head* came
  back, and the two spans it splits the exchange into — server think-time
  (`ttfbMs`) and body transfer (`receiveMs`), which sum to `durationMs`. "This
  call is slow" has a different cause depending on which half it lands in.
  Absent while pending, for a flow that failed before any head, and for a blind
  CONNECT tunnel; `receiveMs` needs both ends, so a flow with a head but no
  completion carries `ttfbMs` alone rather than a guess.
- `payload.status`: HTTP status when a response is available.
- `payload.tunnel`: true for HTTPS CONNECT tunnel observations.
- `payload.mitm`: true only for decrypted HTTPS requests admitted by the MITM
  allowlist.
- `payload.ruleApplied`: true when a traffic rule acted on this exchange (mock,
  block, mapRemote, or a request/response modifier).
- `payload.ruleId`, `payload.ruleAction`: the rule that acted and which route
  fired (`mock` | `block` | `mapRemote` | `passthrough`).
- `payload.mockValueId`: the response value id, present only when `ruleAction`
  is `mock`.
- `payload.requestHeaders`, `payload.responseHeaders`: display-safe HTTP
  headers. Sensitive values such as `Authorization`, `Cookie`, `Set-Cookie`, and
  proxy credentials are redacted before they enter the event log.
- `payload.error`: proxy or upstream failure text for `network.error`.
- `payload.requestBodyBytes`, `payload.responseBodyBytes`: the captured body
  size in bytes, present when a body was stored.
- `payload.requestBodyTruncated`, `payload.responseBodyTruncated`: true when the
  stored artifact was capped below the full body size.

The `network.*` payload has its own authoritative typed schema at
`reticle-protocol/schema/network-event-payload.schema.json` (the event envelope's
`payload` is otherwise open). The Swift host is the sole producer; a Kotlin
contract test validates the golden fixtures against the schema, and a Swift test
pins the emitter's field set to the same schema so neither side can drift.
Golden fixtures: `network-request-event.golden.json`,
`network-response-event.golden.json`, `network-error-event.golden.json`,
`network-websocket-event.golden.json`, `network-advisory-event.golden.json`,
`network-advisory-eviction-event.golden.json`.

### Capture advisories

`network.advisory` is the capture lane reporting on itself, under
`reticle-protocol/schema/network-advisory-payload.schema.json`. Capture degrading
is a fact about the evidence, so it lands *in* the evidence rather than in a log
line nobody reads.

The lane drains the engine's flow stream immediately and does its artifact writes
on a worker, so the engine is never back-pressured into dropping flows. The
worker's backlog is bounded (4096 flows) — an unbounded one is just a memory leak
with better manners — and overflowing it is reported as two edges:

- `payload.kind: capture-backlog-overflow` — recording started falling behind.
  Carries `droppedFlowsTotal`; **not** `droppedFlows`, because the episode is still
  open and the size of the gap is not yet knowable.
- `payload.kind: capture-backlog-recovered` — it caught up. Carries `droppedFlows`
  for the episode plus the running `droppedFlowsTotal`.

Two edges rather than one event per dropped flow, so a drop storm does not become
its own flood. An overflow with no matching recovered event means the session ended
while still dropping; `droppedFlowsTotal` says how much had been lost by then.

Bodies are also bounded, on disk rather than in memory. `network-bodies/` grows one
artifact per flow and nothing above it expires (`AutoSession.prune()` evicts whole
*past* sessions and deliberately skips the one being written), so the body store keeps
the session inside a byte budget (256 MB by default) by dropping the oldest artifacts:

- `payload.kind: body-budget-eviction` — stored bodies passed the budget, so the
  oldest were dropped. Carries `evictedBodiesTotal` and `evictedBytesTotal`, and
  **not** `droppedFlowsTotal`: the flows themselves were captured in full, with their
  events, headers, timings and sizes intact. Announced once per episode, re-armed when
  a write evicts nothing.

Fetching an evicted body's ref answers `410` with `body:evicted — this body held N
bytes …` rather than a bare `404`. `events.jsonl` is append-only and an event that has
aged out of the in-memory ring must stay fetchable, so the ref cannot be rewritten
after the fact; the store's `network-bodies/evicted.jsonl` ledger is what keeps the
distinction between "dropped for space" and "never existed" answerable.

**What this cannot cover:** the engine's own stream buffer. `AsyncStream` gives a
subscriber no way to learn it dropped something, so if the engine ever drops
despite being drained immediately, that loss is invisible to Reticle and no
advisory can be emitted for it. Detecting it would need a dropped-flow counter on
the engine side.

### WebSocket frames

An upgraded socket is still an ordinary flow: its handshake produces a
`network.request` and a `network.response` with `status: 101`. What happens
*inside* it arrives as `network.websocket` events under the same
`payload.requestId`, one per frame — not an array on the flow, because a socket
may stay open for the whole session and a summary at close is evidence that may
never come. Its payload has its own schema,
`reticle-protocol/schema/network-websocket-payload.schema.json`:

- `payload.frameIndex`: zero-based position in the socket's frame sequence.
- `payload.direction`: `clientToServer` | `serverToClient`.
- `payload.kind`: `text` | `binary` | `ping` | `pong` | `close` | `continuation`.
- `payload.isFinal`: false for a fragment continued by later `continuation` frames.
- `payload.bytes`, `payload.frameMillis`: wire size and observation time.
- `payload.textPreview`, `payload.textPreviewTruncated`: UTF-8 preview of a text
  frame, capped at 512 bytes. A binary frame has no text reading and carries no
  preview. A frame too big to sit inline also has its whole payload under `refs`
  as `wsFrame.<requestId>.<frameIndex>`; a small frame carries no artifact, so a
  chatty socket does not strew thousands of files.

Two caps sit above this, and hitting either emits one final `network.websocket`
event with `payload.capReached: true`, `framesRecorded`, and — when the capture
engine reported a count — `framesNotRecorded`. **The socket is still open and may
still be talking**: the silence after that notice is the cap, not a quiet socket,
and reading it as one is the mistake the event exists to prevent. Reticle stops
after 1000 frames per socket so a single chatty socket cannot bury the session;
the capture engine has its own 10k-frame / 5 MB cap, which can bite first on a
few large frames.

Responses are **streamed** back to the client as they arrive off the upstream
socket, not buffered whole. An identity body with a known length is forwarded
under its original `Content-Length`; a decoded or unknown-length body is
forwarded under `Transfer-Encoding: chunked`. A slow client back-pressures the
upstream fetch (the transfer is suspended until the client drains), so a large
response cannot force the daemon to hold it all in memory. The terminal
`network.response` (or `network.error`) event is emitted when the stream
finishes, so a consumer polling immediately after the client's last byte may
briefly see the response before its event lands.

Request and response bodies are never inlined. If captured, they are written
under the session directory and referenced through `refs`, for example
`requestBody.<requestId>` or `responseBody.<requestId>`. The stored response
artifact is capped at the body limit while the full body still reaches the
client; `responseBodyBytes` reports the true transfer size and
`responseBodyTruncated` flags the cap. Body refs are subject to the same artifact
endpoint restrictions as screenshots and trace manifests.

Android device capture uses host-controlled proxy settings (`adb reverse` plus
global `http_proxy`) and restores the previous proxy value when the daemon exits.
Plain HTTP is captured directly. HTTPS CONNECT is timed as a tunnel unless
`--proxy-mitm` and `--proxy-ssl-hosts` admit the host. In MITM mode Reticle
generates a local CA (default `~/.reticle/proxy-ca`, override with
`--proxy-ca-dir`) and signs per-host leaf certificates on demand. `--proxy-install-ca`
pushes the DER CA file to Android and opens Security settings, but Android 11+
still requires user confirmation in Settings before apps can trust that CA.
Certificate pinning, apps that ignore user CAs, and untrusted CAs remain opaque
by design.

## Network rules

Traffic rules are owned by `reticle serve`; the Android agent and helper do not
rewrite app behavior. The daemon persists rule configuration next to the session:

- `rules.json`: rule metadata (`id`, `enabled`, `priority`, `method`, `url`,
  `match`, optional `host`, optional `query`, and `actions`).
- `rule-values.json`: mock response metadata (`id`, `status`, `headers`,
  `bodyRef`, `contentType`), referenced by a rule's `mock` action.
- `rule-values/<valueId>.body`: response body bytes.

A rule's `actions.route` is one of `mock` (reply with a stored value), `block`
(fail the connection), `mapRemote` (re-target the request at another origin, keeping
path + query), or `passthrough` (fetch upstream unchanged). Orthogonal modifiers
compose with any route: `delayMs`, request/response header rewrites, and
request/response find/replace substitutions.

Rules match only traffic visible to the host proxy. Plain HTTP can be modified
directly. HTTPS requests can be modified only after MITM decryption; opaque CONNECT
tunnels expose only the target host/port and are not modifiable in v1. Matching is
method-scoped, and `method` may be `ANY` to match every method. A rule `url` that
starts with `/` matches the request path; otherwise it matches the full URL.
`match` is `exact`, `prefix`, or `regex`. A `regex` rule's `url` is a regular
expression (validated at upsert) matched against both the request path and the
full URL, so either an anchored path pattern (`^/api/users/\d+$`) or a
full-URL pattern works. Optional `host` narrows a rule to one hostname or a
wildcard suffix such as `*.example.test`. Optional `query` is a JSON object;
every declared key/value must be present in the request query (extra query
parameters are allowed), and a value of `"*"` is a presence-only predicate
(the key must exist with any value). Enabled rules are evaluated by descending
`priority`, then stable rule order. `prefix` is a raw string prefix; use `exact`
for short paths when a broader prefix would accidentally cover unrelated
endpoints.

The CLI manages the same REST API:

```bash
reticle rule set --id users --action mock --value-id users-ok \
  --method GET --url /api/users --match prefix --priority 100 \
  --status 200 --headers '{"Content-Type":"application/json"}' \
  --body '{"users":[]}'

reticle rule set --id kill-analytics --action block --method ANY --url /track --match prefix
reticle rule set --id to-staging --map-to https://staging.example.test --method ANY --url /api --match prefix
reticle rule set --id slow-home --action passthrough --delay-ms 3000 --method GET --url /api/home --match prefix
reticle rule disable --id users
reticle rule value set --id users-ok --status 500 --body '{"error":"down"}'
reticle rule test --method GET --url 'http://api.test/api/users?page=1'
reticle rule export --output /tmp/reticle-rules.json
reticle rule clear
reticle rule import --input /tmp/reticle-rules.json
```

## Flow replay

### Finding a flow to replay

`GET /sessions/current/flows` filters the capture engine's retained flows so an
agent can name the exchange it means without pulling every summary into context.
The scan runs over everything retained and only *then* applies `limit`, so a match
older than the newest `limit` exchanges is still findable. Parameters (all
optional, ANDed): `host` (exact or `*.example.com`), `method` (comma-separated),
`urlContains`, `status` (sets both bounds) or `statusMin`/`statusMax`,
`onlyErrors=true`, `sinceMillis`, `limit` (default 50, clamped to 500).

The response is `{ flows, truncatedToLimit, replayableOnly }`, each flow carrying
`requestId`, `method`, `url`, `host`, `status`, `error`, `startMillis`,
`durationMs`, `ttfbMs`, `receiveMs`, body sizes, and `bodyCaptureTruncated`.

**`replayableOnly` is always true and always stated.** This endpoint reads the
capture engine's bounded in-memory ring — the only thing `replay` can act on — not
the session's evidence log. A flow that has aged out of that ring is absent here
while its `network.*` events remain in `events.jsonl`. So an empty result means
"nothing replayable matches", never "this never happened"; for the latter question,
read the events. The endpoint 404s when `serve` is running without a capture proxy,
rather than returning an empty list that would read as "no traffic matched".

`POST /sessions/current/flows/{id}/replay` closes Loom's capture → modify → replay
→ diff loop: it re-sends a captured flow (by its `requestId`) through the engine's
forwarder with optional overrides, then emits a `network.replay` event and returns
the diff. The replay is a host-side re-send — it does not travel back through the
device proxy. Overrides (all optional; empty body = replay verbatim):

- `method`, `url`: replace the request line.
- `setHeaders` (object), `removeHeaders` (array of names): add/overwrite or drop
  request headers.
- `body` (UTF-8) / `bodyBase64` (binary) / `clearBody` (empty): mutually exclusive
  request-body override; omit all three to keep the source body.

The emitted `network.replay` payload carries the replayed exchange's normal fields
plus `payload.replayedFrom` (the source flow id) and a `payload.diff` object of the
replayed response vs the original: `statusFrom`/`statusTo`/`statusChanged`,
`bodyBytesFrom`/`bodyBytesTo`/`bodyChanged`, and `headersAdded`/`headersRemoved`/
`headersChanged`. The header lists carry names only — never values — so a changed
`Authorization` is named without logging the secret. The replayed request/response
bodies are stored as artifacts under the event's `refs`.

`bodyBytesFrom`/`bodyBytesTo` are on-the-wire sizes. When a body was larger than the
capture cap, only a prefix was recorded, and the diff says so with
`payload.diff.bodyComparisonPartial: true` (omitted otherwise). Under that flag
`bodyChanged: false` means *the recorded prefixes match*, not that the responses
match — two different bodies agreeing for their first megabyte land here. Differing
wire sizes still report `bodyChanged: true`, since that much is knowable from a
prefix. A partial comparison is never reported as identical.

```bash
reticle replay flow <request-id> --set-headers '{"X-Debug":"1"}' --remove-headers '["Authorization"]'
reticle replay flow <request-id> --method POST --body '{"retry":true}'
reticle replay flow <request-id> --clear-body
```

## Read-only web panel

`GET /panel` serves a zero-build HTML/CSS/JS panel from the daemon itself. It
loads history from the current or selected session events endpoint, listens for
live `action.trace`, `network.*`, and `runtime.advisory` events over SSE when
the current session is selected, and uses the artifact endpoint above to render
a vertical evidence timeline. One
`action.trace` event is flattened in the UI into screenshot/snapshot evidence
cards around the action plus a compact diff card; the persisted event log
remains unchanged. Action cards include copyable selector/target chips derived
from the trace payload. Runtime advisory events render as standalone cards with
previous/current PID and runtime details. The panel uses a centered axis with a
network request lane.
`network.*` events are grouped by `requestId` into request cards with method,
URL, status, duration, MITM/tunnel/rule-action mode, request/response headers,
body artifact links, small text previews for captured bodies, and copyable rule
id / action / value id when present. Network cards can be filtered by mode
(RULE/ERROR/MITM/TUNNEL), by status class (2xx/3xx/4xx/5xx), and by a free-text
search over method/url/host/path/status/rule ids — the three combine. A view
toggle switches between the interleaved **Timeline** and a **Rule groups** view
that groups rule-applied requests under their rule (with hit counts) and the rest
by host. Each network card carries a **copy as rule** chip that assembles a
ready-to-run `reticle rule set` command (method, path, host, status,
content-type, and `--body-file` pointing at the captured response artifact) and
copies it to the clipboard — the panel stays display-only and never mutates rule
state itself. Diff previews rank user-visible changes ahead of structural churn,
and missing screenshot artifacts render inline errors.

The session picker loads `GET /sessions` and can switch from the live current
session to a persisted historical session. Current keeps the SSE stream open;
history sessions are static reads so replay does not mutate the event log.

Artifact reads are scoped to an event id plus a ref name already present in that
event's `refs`. The endpoint does not accept arbitrary filesystem paths, returns
only regular files, and is intended for local evidence such as `trace.json`,
snapshots, and screenshots.

The panel is display-only. It does not drive input or mutate runtime state.
