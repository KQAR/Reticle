# Network rules — mock, block, map, delay

Read this to make the app see a different network: canned responses, failures,
another origin, added latency. Requires `reticle serve` — see
[daemon-and-panel.md](daemon-and-panel.md). Back to [SKILL.md](../SKILL.md).

Use `reticle rule` only while `reticle serve` is running. Rule configuration is
stored under the current session as separate rule/value files: `rules.json`,
`rule-values.json`, and `rule-values/<valueId>.body`. A rule chooses traffic
(`method`, `url`, `match`, `priority`) and applies an **action**; a mock action
points at a reusable value that owns the fixed response (`status`, `headers`,
body file). Rules can also be narrowed with `--host api.example.test` or
`--host '*.example.test'`, and `--query '{"page":"1"}'` requires those query
key/value pairs while allowing extra query parameters.

Pick the action with `--action` (defaults to `mock`, or `mapRemote` when
`--map-to` is present):

- `mock` — reply with a stored value (network stub / canned response).
- `block` — fail the connection (network-failure evidence).
- `mapRemote --map-to https://staging.example.com [--keep-host-header]` — re-target
  the request at another origin, keeping path + query.
- `passthrough` — fetch upstream unchanged (only useful with a modifier below).

Modifiers compose with any action: `--delay-ms 3000` (latency, for loading/timeout
states), `--set-request-headers '{"X-Debug":"1"}'` / `--remove-request-headers
'["Authorization"]'` (and the `-response-` variants), and `--request-subs` /
`--response-subs` (a JSON array of `{field,match,replacement[,isRegex,caseSensitive]}`
find/replace substitutions).

```bash
reticle rule set --id users --action mock --value-id users-ok \
  --method GET --url /api/users --match prefix --priority 100 \
  --status 200 --headers '{"Content-Type":"application/json"}' \
  --body '{"users":[]}'
reticle rule set --id kill-analytics --action block --method ANY --url /track --match prefix
reticle rule set --id to-staging --map-to https://staging.example.test \
  --method ANY --url /api --match prefix
reticle rule set --id slow-home --action passthrough --delay-ms 3000 \
  --method GET --url /api/home --match prefix
reticle rule disable --id users      # keep the rule, stop applying it
reticle rule enable  --id users      # apply it again
reticle rule remove  --id users      # delete it outright (disable ≠ remove)
reticle rule value set --id users-ok --status 500 --body '{"error":"down"}'
reticle rule test --method GET --url 'http://api.test/api/users?page=1'
reticle rule export --output /tmp/reticle-rules.json
reticle rule clear
reticle rule import --input /tmp/reticle-rules.json
reticle rule list
```

Use `--body` for inline UTF-8 text. Use `--body-file <path>` for files; the CLI
sends file bytes as base64 so binary or non-UTF-8 mock bodies survive
export/import.

## Re-sending one captured request (`replay flow`)

A rule changes what the app sees **next time**. To interrogate a request that
already happened — "does the server still answer without that header?" — replay
it. `reticle replay flow <request-id>` re-sends a captured flow with overrides
and prints the diff against the original response, so the answer is a
comparison, not a second capture you have to eyeball:

```bash
reticle replay flow req-42                                    # verbatim re-send (control run)
reticle replay flow req-42 --remove-headers '["Authorization"]'
reticle replay flow req-42 --set-headers '{"X-Debug":"1"}' --method POST
reticle replay flow req-42 --url https://staging.example.test/api/users
reticle replay flow req-42 --body '{"page":2}'                # or --body-file <path>, or --clear-body
```

The request id is the one the panel's network cards and the `network.*` events
are grouped by — see [daemon-and-panel.md](daemon-and-panel.md). Needs `reticle
serve` running (replay goes through the same engine as capture).

Output is the diff, not the response: `status: 200 -> 401 [changed]`, `body:
1284 -> 39 bytes [changed]`, `headers: +[…] -[…] ~[…]`, and a final `identical:
true/false`. Replay one flow **unchanged** first when you need a baseline —
a server that varies per request makes `identical: false` meaningless on its
own, and the control run is what separates "my override did that" from "this
endpoint never repeats".

For HTTP traffic, rules apply directly in the host proxy. For HTTPS, they only
apply after MITM decryption (`--proxy-mitm --proxy-ssl-hosts <host>` plus app CA
trust, normally via the debug-only `network_security_config` shown in
[daemon-and-panel.md](daemon-and-panel.md)); opaque
CONNECT tunnels cannot be path/body-modified. If a mock rule matches but
its value is missing, Reticle records `network.error` and returns 502 rather
than silently contacting upstream. `prefix` is a raw string prefix; use `exact` for short paths when a broader prefix could match unrelated endpoints.
