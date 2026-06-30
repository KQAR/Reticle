# Reticle daemon event protocol

`reticle serve` owns the local session timeline. It exposes a lightweight
localhost REST/SSE surface and persists every accepted event to:

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
| `GET` | `/sessions` | Current session listing. |
| `GET` | `/sessions/current/events?since=<id>` | Buffered event history after `id`; omit `since` for all retained events. |
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
When a live daemon is discoverable through `~/.reticle/daemon.json`, it also
publishes the written trace as an `action.trace` event on a best-effort basis.
