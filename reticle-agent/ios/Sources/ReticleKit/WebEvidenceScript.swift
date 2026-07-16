import Foundation

/// JavaScript evidence hooks for web content — the injected-script half of
/// `WebEvidence`, borrowing Playwright's design: wrap `console.*`, surface
/// uncaught errors / unhandled rejections, and time `fetch` / `XMLHttpRequest`
/// calls. Events accumulate in an in-page ring buffer (never posted anywhere on
/// their own); the agent drains the buffer whenever it observes the app, which
/// keeps the channel pull-based like every other Reticle observation.
///
/// Install is idempotent (`window.__reticle` guard) and passthrough: original
/// console/fetch/XHR behavior is preserved. All strings are truncated so a
/// noisy page cannot balloon the agent's log ring.
enum WebEvidenceScript {
    /// Installs the hooks in the current document. Returns "installed" or
    /// "already".
    static let install: String = """
        (function() {
          if (window.__reticle) return "already";
          var buf = [];
          var MAX = 200;
          var dropped = 0;
          function push(e) {
            if (buf.length >= MAX) { dropped++; return; }
            e.ts = Date.now();
            buf.push(e);
          }
          function fmt(args) {
            var out = [];
            for (var i = 0; i < args.length && i < 8; i++) {
              var a = args[i];
              try { out.push(typeof a === "string" ? a : JSON.stringify(a)); }
              catch (err) { out.push(String(a)); }
            }
            return out.join(" ").slice(0, 500);
          }
          var names = ["log", "info", "warn", "error", "debug"];
          for (var i = 0; i < names.length; i++) (function(name) {
            var original = console[name] && console[name].bind ? console[name].bind(console) : null;
            console[name] = function() {
              push({ kind: "console", level: name, text: fmt(arguments) });
              if (original) original.apply(null, arguments);
            };
          })(names[i]);
          window.addEventListener("error", function(e) {
            push({ kind: "jsError", level: "error",
              text: String(e.message || e.error || "error").slice(0, 500),
              url: (String(e.filename || "").slice(0, 200)) + (e.lineno ? ":" + e.lineno : "") });
          });
          window.addEventListener("unhandledrejection", function(e) {
            var reason = "";
            try { reason = e.reason && e.reason.message ? e.reason.message : JSON.stringify(e.reason); }
            catch (err) { reason = String(e.reason); }
            push({ kind: "jsError", level: "error",
              text: ("unhandledrejection: " + reason).slice(0, 500) });
          });
          if (window.fetch) {
            var originalFetch = window.fetch.bind(window);
            window.fetch = function(input, init) {
              var url = String(input && input.url ? input.url : input).slice(0, 300);
              var method = ((init && init.method) || (input && input.method) || "GET").toUpperCase();
              var started = Date.now();
              return originalFetch(input, init).then(function(res) {
                push({ kind: "network", level: res.ok ? "info" : "warn", api: "fetch",
                  method: method, url: url, status: res.status, durationMs: Date.now() - started });
                return res;
              }, function(err) {
                push({ kind: "network", level: "error", api: "fetch",
                  method: method, url: url, error: String(err).slice(0, 200), durationMs: Date.now() - started });
                throw err;
              });
            };
          }
          var xhrOpen = XMLHttpRequest.prototype.open;
          var xhrSend = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.open = function(method, url) {
            this.__reticleMethod = String(method || "GET").toUpperCase();
            this.__reticleUrl = String(url).slice(0, 300);
            return xhrOpen.apply(this, arguments);
          };
          XMLHttpRequest.prototype.send = function() {
            var xhr = this;
            var started = Date.now();
            xhr.addEventListener("loadend", function() {
              push({ kind: "network", level: (xhr.status >= 400 || xhr.status === 0) ? "warn" : "info",
                api: "xhr", method: xhr.__reticleMethod || "GET", url: xhr.__reticleUrl || "",
                status: xhr.status, durationMs: Date.now() - started });
            });
            return xhrSend.apply(this, arguments);
          };
          window.__reticle = {
            drain: function() {
              var out = buf;
              buf = [];
              if (dropped > 0) {
                out.push({ kind: "console", level: "warn",
                  text: "reticle: dropped " + dropped + " web events (ring full)", ts: Date.now() });
                dropped = 0;
              }
              return JSON.stringify(out);
            }
          };
          return "installed";
        })();
        """

    /// Drains the ring buffer; returns a JSON array (empty if not installed).
    static let drain: String = """
        (function() { return window.__reticle ? window.__reticle.drain() : "[]"; })();
        """
}
