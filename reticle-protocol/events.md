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
| `GET` | `/sessions/current/mocks/export` | Export rules plus value bodies as a JSON package. |
| `POST` | `/sessions/current/mocks/import` | Import a mock JSON package into the current session. |
| `POST` | `/sessions/current/mocks/clear` | Remove all current-session rules, values, and value body files. |
| `POST` | `/sessions/current/mocks/resolve` | Preview which rule/value would match a method + absolute URL. |
| `GET` | `/sessions/current/mocks/rules` | List current-session network mock rules. |
| `POST` | `/sessions/current/mocks/rules` | Create or update a mock rule. |
| `POST` | `/sessions/current/mocks/rules/{id}/enable` | Enable a mock rule. |
| `POST` | `/sessions/current/mocks/rules/{id}/disable` | Disable a mock rule. |
| `DELETE` | `/sessions/current/mocks/rules/{id}` | Remove a mock rule. |
| `GET` | `/sessions/current/mocks/values` | List current-session mock response values. |
| `POST` | `/sessions/current/mocks/values` | Create or update a mock response value. |
| `DELETE` | `/sessions/current/mocks/values/{id}` | Remove an unreferenced mock value. |
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
- `type`: `network.request`, `network.response`, or `network.error`
- `payload.requestId`: stable id shared by the request/response/error events.
- `payload.method`, `url`, `scheme`, `host`, `port`, `path`: request target.
- `payload.startMillis`, `endMillis`, `durationMs`: request interval timing.
- `payload.status`: HTTP status when a response is available.
- `payload.tunnel`: true for HTTPS CONNECT tunnel observations.
- `payload.mitm`: true only for decrypted HTTPS requests admitted by the MITM
  allowlist.
- `payload.mocked`: true when the proxy returned a configured mock response
  instead of contacting upstream.
- `payload.mockRuleId`, `payload.mockValueId`: the rule/value pair that
  produced a mock response.
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
`network-response-event.golden.json`, `network-error-event.golden.json`.

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

## Network mocks

Mocking is owned by `reticle serve`; the Android agent and helper do not rewrite
app behavior. The daemon persists mock configuration next to the session:

- `mock-rules.json`: rule metadata (`id`, `enabled`, `priority`, `method`,
  `url`, `match`, optional `host`, optional `query`, `valueId`).
- `mock-values.json`: response metadata (`id`, `status`, `headers`, `bodyRef`,
  `contentType`).
- `mock-values/<valueId>.body`: response body bytes.

Rules match only traffic visible to the host proxy. Plain HTTP can be mocked
directly. HTTPS requests can be mocked only after MITM decryption; opaque CONNECT
tunnels expose only the target host/port and are not mockable in v1. Matching is
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
reticle mock set --id users --value-id users-ok \
  --method GET --url /api/users --match prefix --priority 100 \
  --status 200 --headers '{"Content-Type":"application/json"}' \
  --body '{"users":[]}'

reticle mock rule disable --id users
reticle mock value set --id users-ok --status 500 --body '{"error":"down"}'
reticle mock rule test --method GET --url 'http://api.test/api/users?page=1'
reticle mock export --output /tmp/reticle-mocks.json
reticle mock clear
reticle mock import --input /tmp/reticle-mocks.json
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
URL, status, duration, MITM/tunnel/mock mode, request/response headers, body
artifact links, small text previews for captured bodies, and copyable mock
rule/value ids when present. Network cards can be filtered by mode
(MOCK/ERROR/MITM/TUNNEL), by status class (2xx/3xx/4xx/5xx), and by a free-text
search over method/url/host/path/status/mock ids — the three combine. A view
toggle switches between the interleaved **Timeline** and a **Mock groups** view
that groups mocked requests under their mock rule (with hit counts) and the rest
by host. Each network card carries a **copy as mock** chip that assembles a
ready-to-run `reticle mock set` command (method, path, host, status,
content-type, and `--body-file` pointing at the captured response artifact) and
copies it to the clipboard — the panel stays display-only and never mutates mock
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
