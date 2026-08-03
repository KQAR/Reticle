# The daemon, the session event bus, and the panel

Read this when a run needs a durable timeline across many commands, a
browser-visible evidence panel, or network capture. For mocking/rewriting that
traffic see [network-rules.md](network-rules.md). Back to
[SKILL.md](../SKILL.md).

## Session event bus

Use `reticle serve` when you need a durable local timeline across multiple
commands or a browser-visible evidence panel. It creates
`~/.reticle/sessions/<session>/events.jsonl` and exposes REST/SSE plus a
display-only panel on localhost via Hummingbird:

```bash
reticle serve --session demo --port 9876 --proxy-port 9090
open http://127.0.0.1:9876/panel
curl -N http://127.0.0.1:9876/events/stream
```

When the daemon is running, ordinary `act ...` commands automatically write trace
packages under the current session and publish `action.trace` events. The panel
shows a vertical evidence timeline: screenshot/snapshot evidence cards, actions,
and manifest diffs are flattened into time-ordered nodes. Diff previews rank
visible text/label/state changes ahead of structural churn, and missing
screenshot artifacts show inline failures. Its session picker can switch from the
live current session to static historical sessions under `~/.reticle/sessions`.
When `--proxy-port` is supplied, the daemon also records `network.*` events and
renders them in the panel's network lane. Network cards are grouped by request id
and show method, URL, status, duration, headers, body refs, and text previews for
captured bodies; sensitive header values are redacted. Mocked responses are
marked with a `MOCK` badge and show copyable mock rule/value ids. Use the
filter buttons for MOCK, ERROR, MITM, and TUNNEL when a session has many network
events. Add `--proxy-device --serial <id>` to configure Android global proxy through
`adb reverse`; the daemon restores the previous proxy setting on exit. HTTPS
decryption is opt-in via `--proxy-mitm`
and `--proxy-ssl-hosts`; Reticle generates a local CA under
`~/.reticle/proxy-ca` unless `--proxy-ca-dir` is supplied. Use
`--proxy-install-ca` to push the CA file and open Android Security settings.
Android 11+ still requires the user to confirm CA trust in Settings, and apps
that ignore user CAs or pin certificates remain opaque.

For Android HTTPS debugging, prefer the debug-flavor trust path. Tell the user
explicitly that this requires an app source change and a rebuild/reinstall, but
only affects the debug variant when placed under the debug source set. Add a
debug-only `network_security_config` that trusts user CAs, then reference it
from the debug manifest/application merge:

```xml
<!-- app/src/debug/res/xml/network_security_config.xml -->
<network-security-config>
  <debug-overrides>
    <trust-anchors>
      <certificates src="user" />
      <certificates src="system" />
    </trust-anchors>
  </debug-overrides>
</network-security-config>
```

```xml
<!-- app/src/debug/AndroidManifest.xml, or an equivalent debug-only manifest merge -->
<application android:networkSecurityConfig="@xml/network_security_config" />
```

Do not present root/system CA installation or runtime trust-manager patching as
the default Reticle workflow. Those are environment-specific escape hatches.
The normal path is: debug build trusts user CA, user installs/confirms the
Reticle CA, then Reticle runs `--proxy-mitm --proxy-ssl-hosts <host>`.
