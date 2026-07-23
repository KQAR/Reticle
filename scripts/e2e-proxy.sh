#!/usr/bin/env bash
# End-to-end smoke test for the host-side network lane: `reticle serve` with the
# capture proxy, mock rules driven through the `reticle mock` CLI (which rides
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
SESSION="e2e-proxy-$$"
# Which capture engine to exercise: `loom` (Loom's engine via LoomCaptureLane,
# the default) or `builtin` (the legacy in-tree NIO proxy). The two emit tunnel
# events differently, so the CONNECT-tunnel assertions below branch on engine.
ENGINE="${E2E_PROXY_ENGINE:-loom}"

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
cleanup() {
  [ -n "$SERVE_PID" ] && kill "$SERVE_PID" 2>/dev/null || true
  [ -n "$UPSTREAM_PID" ] && kill "$UPSTREAM_PID" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT

echo "== upstream fixture =="
mkdir -p "$TMP/www"
printf 'real upstream body' > "$TMP/www/real.txt"
/usr/bin/python3 -m http.server "$UPSTREAM_PORT" --bind 127.0.0.1 --directory "$TMP/www" >/dev/null 2>&1 &
UPSTREAM_PID=$!

echo "== serve with proxy + mitm (engine=$ENGINE) =="
"$HOST" serve --session "$SESSION" --port "$DAEMON_PORT" \
  --proxy-port "$PROXY_PORT" --proxy-mitm true --proxy-ssl-hosts 127.0.0.1 \
  --proxy-ca-dir "$TMP/ca" --proxy-engine "$ENGINE" >"$TMP/serve.log" 2>&1 &
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
"$HOST" mock set --id e2e-http --method GET --url "http://reticle-e2e.invalid/hello" \
  --status 200 --content-type application/json --body '{"mocked":"http"}'
"$HOST" mock set --id e2e-https --method GET --url "https://127.0.0.1:$UPSTREAM_PORT/api" \
  --match prefix --status 201 --content-type application/json --body '{"mocked":"https"}'
"$HOST" mock list | grep -q "e2e-http" || { echo "FAIL: mock list missing e2e-http"; exit 1; }
"$HOST" mock rule test --method GET --url "http://reticle-e2e.invalid/hello" \
  | grep -q "matched rule=e2e-http" || { echo "FAIL: mock rule test did not match e2e-http"; exit 1; }

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

echo "== blind HTTPS tunnel (out-of-scope host) =="
# `localhost` resolves to the same upstream, but the CONNECT authority host
# ("localhost") is outside --proxy-ssl-hosts (127.0.0.1), so it's blind-tunneled
# rather than MITM-decrypted. The TLS handshake fails against the plain-HTTP
# upstream (|| true); the point is that the CONNECT tunnel itself is observed.
curl -s --max-time 8 -o /dev/null -x "$PROXY" -k "https://localhost:$UPSTREAM_PORT/" || true

echo "== mock clear falls through to upstream =="
"$HOST" mock clear
CODE="$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' -x "$PROXY" "http://reticle-e2e.invalid/hello" || true)"
[ "$CODE" = "502" ] || { echo "FAIL: cleared mock should 502 on a dead upstream, got $CODE"; exit 1; }

echo "== evidence trail in events.jsonl =="
/usr/bin/python3 - "$EVENTS" "$UPSTREAM_PORT" "$ENGINE" <<'PY'
import json, sys

events = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
port = sys.argv[2]
engine = sys.argv[3]

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

mocked = find("network.response", url="http://reticle-e2e.invalid/hello", mocked=True)
mocked or fail("no mocked network.response for the plaintext hit")
mocked["payload"].get("mockRuleId") == "e2e-http" or fail("plaintext mock response missing mockRuleId=e2e-http")
find("network.request", url="http://reticle-e2e.invalid/hello") or fail("no network.request for the plaintext hit")

https = find("network.response", mocked=True, status=201)
https or fail("no mocked network.response for the HTTPS hit")
https["payload"].get("mitm") is True or fail("HTTPS mocked response not flagged mitm")
# The built-in proxy emits a blind-tunnel event for the CONNECT; Loom only
# surfaces flows it observed (decrypted), so it has no tunnel event by design.
if engine == "builtin":
    find("network.response", tunnel=True, mitm=True) or fail("no MITM CONNECT response event")

# Loom emits a tunnel event only for un-decrypted (blind) CONNECTs — the
# out-of-scope localhost tunnel above — with its observeTunnels enabled.
if engine == "loom":
    tun = find("network.response", tunnel=True, mitm=False)
    tun or fail("no blind-tunnel event for the out-of-scope CONNECT")
    tun["payload"].get("method") == "CONNECT" or fail("blind-tunnel event not marked CONNECT")

real = find("network.response", url=f"http://127.0.0.1:{port}/real.txt")
real or fail("no network.response for the real upstream forward")
real["payload"].get("mocked") and fail("real forward wrongly flagged as mocked")
real["payload"].get("status") == 200 or fail(f"real forward status {real['payload'].get('status')} != 200")

find("network.error", url="http://reticle-e2e.invalid/hello") or fail("no network.error after mock clear")

# The mocked body must be persisted as fetchable evidence, not just streamed.
ref = next((v for k, v in (mocked.get("refs") or {}).items() if k.startswith("responseBody")), None)
ref or fail("mocked response carries no responseBody ref")
open(ref, "rb").read() == b'{"mocked":"http"}' or fail("stored mock body does not match the rule value")
print("events: ok")
PY

echo "== OK: artifacts in $TMP =="
