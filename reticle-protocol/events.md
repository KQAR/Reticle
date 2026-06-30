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
| `POST` | `/sessions/current/events` | Append a daemon-stamped event body. |
| `POST` | `/sessions/current/action-traces` | Ingest an existing action `trace.json` or `{ "path": "/.../trace.json" }`. |
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

## Read-only web panel

`GET /panel` serves a zero-build HTML/CSS/JS panel from the daemon itself. It
loads history from the current or selected session events endpoint, listens for
live `action.trace` events over SSE when the current session is selected, and
uses the artifact endpoint above to render a vertical evidence timeline. One
`action.trace` event is flattened in the UI into screenshot/snapshot evidence
cards around the action plus a compact diff card; the persisted event log
remains unchanged. The panel uses a centered axis with a reserved lane for future
interval-style network request events. Diff previews rank user-visible changes
ahead of structural churn, and missing screenshot artifacts render inline errors.

The session picker loads `GET /sessions` and can switch from the live current
session to a persisted historical session. Current keeps the SSE stream open;
history sessions are static reads so replay does not mutate the event log.

Artifact reads are scoped to an event id plus a ref name already present in that
event's `refs`. The endpoint does not accept arbitrary filesystem paths, returns
only regular files, and is intended for local evidence such as `trace.json`,
snapshots, and screenshots.

The panel is display-only. It does not drive input, mutate runtime state, or show
network proxy traffic; future proxy events can reuse the same event stream.
