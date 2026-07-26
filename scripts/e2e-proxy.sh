#!/usr/bin/env bash
# End-to-end smoke test for the host-side network lane: `reticle serve` with the
# capture proxy, traffic rules driven through the `reticle rule` CLI (which rides
# the daemon HTTP API), a plaintext mock hit, an HTTPS hit decrypted by MITM, a
# real upstream forward, and the network.* evidence trail in events.jsonl.
# This is the wiring the unit tests can't see: CLI -> discovery -> daemon ->
# proxy -> session store, all through real processes and real sockets.
#
# Host-only — no simulator, no device. Requires a built ReticleHost binary
# (swift build --package-path reticle-host), or pass one via RETICLE_HOST.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
HOST="${RETICLE_HOST:-$ROOT/reticle-host/.build/debug/ReticleHost}"
TMP="$(mktemp -d)"
DAEMON_PORT="${E2E_DAEMON_PORT:-19876}"
PROXY_PORT="${E2E_PROXY_PORT:-19090}"
UPSTREAM_PORT="${E2E_UPSTREAM_PORT:-18080}"
WS_PORT="${E2E_WS_PORT:-18081}"
SESSION="e2e-proxy-$$"

[ -x "$HOST" ] || { echo "build the host first: swift build --package-path reticle-host"; exit 1; }

# `serve` overwrites the global ~/.reticle/daemon.json discovery file and the
# owned entry is cleared on exit — running this against a live daemon would
# strand it undiscoverable. Refuse instead.
if /usr/bin/python3 -c 'import json,os,sys
try:
    info = json.load(open(os.path.expanduser("~/.reticle/daemon.json")))
    os.kill(int(info["pid"]), 0)
except Exception:
    sys.exit(1)'; then
  echo "a live reticle serve is already running; stop it before the proxy e2e"; exit 1
fi

SERVE_PID=""
UPSTREAM_PID=""
WS_PID=""
cleanup() {
  [ -n "$SERVE_PID" ] && kill "$SERVE_PID" 2>/dev/null || true
  [ -n "$UPSTREAM_PID" ] && kill "$UPSTREAM_PID" 2>/dev/null || true
  [ -n "$WS_PID" ] && kill "$WS_PID" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT

echo "== upstream fixture =="
mkdir -p "$TMP/www"
printf 'real upstream body' > "$TMP/www/real.txt"
/usr/bin/python3 -m http.server "$UPSTREAM_PORT" --bind 127.0.0.1 --directory "$TMP/www" >/dev/null 2>&1 &
UPSTREAM_PID=$!

echo "== serve with proxy + mitm =="
"$HOST" serve --session "$SESSION" --port "$DAEMON_PORT" \
  --proxy-port "$PROXY_PORT" --proxy-mitm true --proxy-ssl-hosts 127.0.0.1 \
  --proxy-ca-dir "$TMP/ca" >"$TMP/serve.log" 2>&1 &
SERVE_PID=$!
for _ in $(seq 1 50); do
  grep -q "reticle serve: events " "$TMP/serve.log" 2>/dev/null && break
  kill -0 "$SERVE_PID" 2>/dev/null || { cat "$TMP/serve.log"; echo "FAIL: serve exited early"; exit 1; }
  sleep 0.2
done
grep -q "reticle serve: proxy http://127.0.0.1:$PROXY_PORT" "$TMP/serve.log" \
  || { cat "$TMP/serve.log"; echo "FAIL: serve did not start the proxy"; exit 1; }
EVENTS="$(sed -n 's/^reticle serve: events //p' "$TMP/serve.log" | head -1)"
[ -f "$EVENTS" ] || { echo "FAIL: events.jsonl missing at $EVENTS"; exit 1; }
PROXY="http://127.0.0.1:$PROXY_PORT"

echo "== mock rules via CLI =="
"$HOST" rule set --id e2e-http --method GET --url "http://reticle-e2e.invalid/hello" \
  --status 200 --content-type application/json --body '{"mocked":"http"}'
"$HOST" rule set --id e2e-https --method GET --url "https://127.0.0.1:$UPSTREAM_PORT/api" \
  --match prefix --status 201 --content-type application/json --body '{"mocked":"https"}'
"$HOST" rule list | grep -q "e2e-http" || { echo "FAIL: rule list missing e2e-http"; exit 1; }
"$HOST" rule test --method GET --url "http://reticle-e2e.invalid/hello" \
  | grep -q "matched rule=e2e-http" || { echo "FAIL: rule test did not match e2e-http"; exit 1; }

echo "== plaintext HTTP mock hit =="
# The host is .invalid (never resolves): a mock hit must answer without ever
# touching upstream DNS.
BODY="$(curl -sS --max-time 10 -x "$PROXY" "http://reticle-e2e.invalid/hello")"
[ "$BODY" = '{"mocked":"http"}' ] || { echo "FAIL: HTTP mock body mismatch: $BODY"; exit 1; }

echo "== HTTPS mock hit through MITM =="
# CONNECT pre-dials the target, so the python server doubles as the TCP
# endpoint; the mock then answers inside the decrypted stream and the plaintext
# upstream never sees a byte of HTTPS traffic. curl verifying against the
# generated CA proves the whole chain: CA on disk, per-host leaf, IP SAN.
CODE="$(curl -sS --max-time 10 -o "$TMP/https-body" -w '%{http_code}' \
  --cacert "$TMP/ca/reticle-ca.pem" -x "$PROXY" "https://127.0.0.1:$UPSTREAM_PORT/api/hello")"
[ "$CODE" = "201" ] || { echo "FAIL: HTTPS mock status $CODE != 201"; exit 1; }
grep -q '"mocked":"https"' "$TMP/https-body" || { echo "FAIL: HTTPS mock body mismatch"; exit 1; }

echo "== real upstream forward (no mock) =="
BODY="$(curl -sS --max-time 10 -x "$PROXY" "http://127.0.0.1:$UPSTREAM_PORT/real.txt")"
[ "$BODY" = "real upstream body" ] || { echo "FAIL: forwarded body mismatch: $BODY"; exit 1; }

echo "== replay a captured flow with a header override =="
# The response event is flushed asynchronously after curl returns, so poll the
# evidence log briefly for the real.txt forward's requestId, then replay it.
RID=""
for _ in $(seq 1 25); do
  RID="$(/usr/bin/python3 - "$EVENTS" <<'PY'
import json, sys
rid = ""
for line in open(sys.argv[1]):
    if not line.strip():
        continue
    e = json.loads(line)
    p = e.get("payload", {})
    if e.get("type") == "network.response" and p.get("url", "").endswith("/real.txt"):
        rid = p.get("requestId", "")
print(rid)
PY
)"
  [ -n "$RID" ] && break
  sleep 0.2
done
[ -n "$RID" ] || { echo "FAIL: no requestId for the real.txt forward to replay"; exit 1; }
REPLAY_OUT="$("$HOST" replay flow "$RID" --set-headers '{"X-Reticle-Replay":"1"}')"
echo "$REPLAY_OUT"
echo "$REPLAY_OUT" | grep -q "replay flow: " || { echo "FAIL: replay flow produced no result"; exit 1; }

echo "== websocket frames through the proxy =="
# A real socket, upgraded through the real proxy: the unit tests pin how a Loom
# frame becomes an event, but only this proves the frames arrive at all. Raw
# RFC 6455 on both ends so the script keeps its no-dependency rule.
cat > "$TMP/ws.py" <<'PY'
import base64, hashlib, os, socket, struct, sys

GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

def read_head(sock):
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(1)
        if not chunk:
            raise SystemExit("peer closed during handshake")
        buf += chunk
    return buf.decode("latin-1")

def send_frame(sock, payload, opcode=0x1, mask=False):
    header = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        header += bytes([(0x80 if mask else 0) | n])
    else:
        header += bytes([(0x80 if mask else 0) | 126]) + struct.pack("!H", n)
    if mask:
        key = os.urandom(4)
        payload = bytes(b ^ key[i % 4] for i, b in enumerate(payload))
        header += key
    sock.sendall(header + payload)

def read_frame(sock):
    head = sock.recv(2)
    if len(head) < 2:
        return None, b""
    opcode = head[0] & 0x0F
    masked = head[1] & 0x80
    length = head[1] & 0x7F
    if length == 126:
        length = struct.unpack("!H", sock.recv(2))[0]
    key = sock.recv(4) if masked else None
    data = b""
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        if not chunk:
            break
        data += chunk
    if key:
        data = bytes(b ^ key[i % 4] for i, b in enumerate(data))
    return opcode, data

def serve(port):
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", port))
    listener.listen(4)
    # Announce readiness here rather than letting the script probe the port: a
    # connect-and-drop probe would be accepted as the one real client and the
    # handshake would then never come.
    print("READY", flush=True)
    while True:
        conn, _ = listener.accept()
        try:
            head = read_head(conn)
        except SystemExit:
            conn.close()          # a probe or a dropped connection, not our client
            continue
        break
    key = ""
    for line in head.split("\r\n"):
        if line.lower().startswith("sec-websocket-key:"):
            key = line.split(":", 1)[1].strip()
    accept = base64.b64encode(hashlib.sha1(key.encode() + GUID).digest()).decode()
    conn.sendall((
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
    ).encode())
    opcode, data = read_frame(conn)          # the client's "subscribe"
    send_frame(conn, b"tick-1")              # two frames back, unmasked
    send_frame(conn, b"tick-2")
    read_frame(conn)                         # wait for close, then go
    conn.close()

def client(proxy_port, ws_port):
    sock = socket.create_connection(("127.0.0.1", proxy_port), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode()
    # Absolute-form request URI: this is an HTTP proxy, not the origin.
    sock.sendall((
        f"GET http://127.0.0.1:{ws_port}/live HTTP/1.1\r\n"
        f"Host: 127.0.0.1:{ws_port}\r\n"
        "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
    ).encode())
    head = read_head(sock)
    if "101" not in head.split("\r\n")[0]:
        raise SystemExit(f"upgrade refused: {head.splitlines()[0]}")
    send_frame(sock, b"subscribe", mask=True)
    got = []
    for _ in range(2):
        _, data = read_frame(sock)
        got.append(data)
    send_frame(sock, b"", opcode=0x8, mask=True)
    sock.close()
    if got != [b"tick-1", b"tick-2"]:
        raise SystemExit(f"unexpected frames: {got}")

if sys.argv[1] == "serve":
    serve(int(sys.argv[2]))
else:
    client(int(sys.argv[2]), int(sys.argv[3]))
PY
/usr/bin/python3 "$TMP/ws.py" serve "$WS_PORT" >"$TMP/ws-server.log" 2>&1 &
WS_PID=$!
for _ in $(seq 1 50); do
  grep -q READY "$TMP/ws-server.log" 2>/dev/null && break
  sleep 0.1
done
grep -q READY "$TMP/ws-server.log" 2>/dev/null \
  || { cat "$TMP/ws-server.log"; echo "FAIL: websocket fixture never came up"; exit 1; }
/usr/bin/python3 "$TMP/ws.py" client "$PROXY_PORT" "$WS_PORT" \
  || { cat "$TMP/ws-server.log"; echo "FAIL: websocket exchange through the proxy failed"; exit 1; }
echo "websocket: 1 sent, 2 received"

echo "== find a replayable flow by filter =="
# Server-side filtering over the engine's ring: the point is that a match is found
# by predicate rather than by pulling every summary and sifting them here.
FOUND="$(curl -sS --max-time 10 "http://127.0.0.1:$DAEMON_PORT/sessions/current/flows?urlContains=real.txt&status=200&limit=5")"
/usr/bin/python3 - "$FOUND" "$RID" <<'PY'
import json, sys
result = json.loads(sys.argv[1])
expected_id = sys.argv[2]
result.get("replayableOnly") is True or sys.exit("FAIL: flow list did not declare replayableOnly")
flows = result.get("flows", [])
flows or sys.exit("FAIL: filter matched no flows for real.txt")
all("real.txt" in f["url"] for f in flows) or sys.exit("FAIL: filter returned a non-matching url")
all(f["status"] == 200 for f in flows) or sys.exit("FAIL: status filter not applied")
# The flow we replayed earlier must be findable by predicate.
expected_id in {f["requestId"] for f in flows} or sys.exit(
    f"FAIL: the replayed flow {expected_id} was not findable by filter")
# Timing rides along on the summary, so choosing a flow doesn't need a second read.
hit = next(f for f in flows if f["requestId"] == expected_id)
"ttfbMs" in hit or sys.exit("FAIL: summary missing ttfbMs")
print(f"flows: {len(flows)} match, replayable-only")
PY
# A predicate that matches nothing must come back empty, not fall back to "recent".
EMPTY="$(curl -sS --max-time 10 "http://127.0.0.1:$DAEMON_PORT/sessions/current/flows?host=nope.invalid")"
/usr/bin/python3 -c "
import json,sys
r=json.loads(sys.argv[1])
r.get('flows') == [] or sys.exit('FAIL: a non-matching host filter returned flows')
" "$EMPTY"

echo "== blind HTTPS tunnel (out-of-scope host) =="
# `localhost` resolves to the same upstream, but the CONNECT authority host
# ("localhost") is outside --proxy-ssl-hosts (127.0.0.1), so it's blind-tunneled
# rather than MITM-decrypted. The TLS handshake fails against the plain-HTTP
# upstream (|| true); the point is that the CONNECT tunnel itself is observed.
curl -s --max-time 8 -o /dev/null -x "$PROXY" -k "https://localhost:$UPSTREAM_PORT/" || true

echo "== mock clear falls through to upstream =="
"$HOST" rule clear
CODE="$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' -x "$PROXY" "http://reticle-e2e.invalid/hello" || true)"
[ "$CODE" = "502" ] || { echo "FAIL: cleared mock should 502 on a dead upstream, got $CODE"; exit 1; }

echo "== evidence trail in events.jsonl =="
# Frame events are flushed asynchronously after the socket closes; poll rather
# than race the writer.
for _ in $(seq 1 25); do
  COUNT="$(grep -c '"network.websocket"' "$EVENTS" 2>/dev/null || true)"
  [ "${COUNT:-0}" -ge 3 ] && break
  sleep 0.2
done
/usr/bin/python3 - "$EVENTS" "$UPSTREAM_PORT" "$RID" <<'PY'
import json, sys

events = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
port = sys.argv[2]
replayed_from = sys.argv[3]

def fail(message):
    print(f"FAIL: {message}")
    sys.exit(1)

def find(event_type, **payload_preds):
    for event in events:
        if event.get("type") != event_type:
            continue
        payload = event.get("payload", {})
        if all(payload.get(k) == v for k, v in payload_preds.items()):
            return event
    return None

mocked = find("network.response", url="http://reticle-e2e.invalid/hello", ruleApplied=True)
mocked or fail("no rule-applied network.response for the plaintext hit")
mocked["payload"].get("ruleId") == "e2e-http" or fail("plaintext mock response missing ruleId=e2e-http")
mocked["payload"].get("ruleAction") == "mock" or fail("plaintext mock response missing ruleAction=mock")
find("network.request", url="http://reticle-e2e.invalid/hello") or fail("no network.request for the plaintext hit")

https = find("network.response", ruleApplied=True, status=201)
https or fail("no rule-applied network.response for the HTTPS hit")
https["payload"].get("mitm") is True or fail("HTTPS mocked response not flagged mitm")
# The engine emits a tunnel event only for un-decrypted (blind) CONNECTs — the
# out-of-scope localhost tunnel above — via its observeTunnels option.
tun = find("network.response", tunnel=True, mitm=False)
tun or fail("no blind-tunnel event for the out-of-scope CONNECT")
tun["payload"].get("method") == "CONNECT" or fail("blind-tunnel event not marked CONNECT")

real = find("network.response", url=f"http://127.0.0.1:{port}/real.txt")
real or fail("no network.response for the real upstream forward")
real["payload"].get("ruleApplied") and fail("real forward wrongly flagged as rule-applied")
real["payload"].get("status") == 200 or fail(f"real forward status {real['payload'].get('status')} != 200")

# Timing split: a real forward has a response head, so server think-time and
# transfer time are both reportable and must add up to the total.
rp = real["payload"]
for field in ("firstByteMillis", "ttfbMs", "receiveMs"):
    field in rp or fail(f"real forward missing {field}")
rp["ttfbMs"] + rp["receiveMs"] == rp["durationMs"] or fail(
    f"ttfbMs {rp['ttfbMs']} + receiveMs {rp['receiveMs']} != durationMs {rp['durationMs']}")

# WebSocket: the upgrade is an ordinary flow, and the frames inside it are their
# own events — one per frame, in order, both directions, with the close observed.
frames = [e for e in events if e.get("type") == "network.websocket"]
len(frames) >= 3 or fail(f"expected at least 3 websocket frame events, got {len(frames)}")
ids = {f["payload"]["requestId"] for f in frames}
len(ids) == 1 or fail(f"frames split across {len(ids)} sockets, expected 1")
find("network.request", requestId=frames[0]["payload"]["requestId"]) \
    or fail("websocket frames have no upgrade network.request to join")
[f["payload"]["frameIndex"] for f in frames] == list(range(len(frames))) \
    or fail("websocket frame indices are not a dense ordered sequence")

sent = [f for f in frames if f["payload"]["direction"] == "clientToServer"]
received = [f for f in frames if f["payload"]["direction"] == "serverToClient"]
sent or fail("no client-to-server frame recorded")
len(received) == 2 or fail(f"expected 2 server-to-client frames, got {len(received)}")
sent[0]["payload"].get("textPreview") == "subscribe" or fail(
    f"first sent frame preview {sent[0]['payload'].get('textPreview')!r} != 'subscribe'")
[f["payload"].get("textPreview") for f in received] == ["tick-1", "tick-2"] or fail(
    "server frames did not arrive as tick-1, tick-2")
# A small frame is wholly inside its event — no artifact strewn per frame.
sent[0].get("refs") in (None, {}) or fail("a small frame should not spill an artifact")
any(f["payload"].get("kind") == "close" for f in frames) or fail("the close frame was not observed")

find("network.error", url="http://reticle-e2e.invalid/hello") or fail("no network.error after mock clear")

# The replayed flow surfaces as one network.replay event carrying the source id
# and a diff. Replaying real.txt verbatim (only adding a request header) leaves the
# response identical, so the diff must report no status/body change.
replay = find("network.replay", replayedFrom=replayed_from)
replay or fail("no network.replay event referencing the replayed source flow")
diff = replay["payload"].get("diff") or fail("network.replay event missing diff")
diff.get("statusChanged") is False or fail("replay of an unchanged endpoint reported a status change")
diff.get("bodyChanged") is False or fail("replay of an unchanged endpoint reported a body change")

# The mocked body must be persisted as fetchable evidence, not just streamed.
ref = next((v for k, v in (mocked.get("refs") or {}).items() if k.startswith("responseBody")), None)
ref or fail("mocked response carries no responseBody ref")
open(ref, "rb").read() == b'{"mocked":"http"}' or fail("stored mock body does not match the rule value")
print("events: ok")
PY

echo "== OK: artifacts in $TMP =="
