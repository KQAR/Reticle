import Foundation

/// JavaScript used by `WebActivation` to fire a click on a DOM element resolved
/// by its emitted `domCssSelector` chain — the web analogue of `act activate`.
///
/// Borrowed from Playwright's injected-script design: resolve the `>>>` chain
/// through open shadow roots / same-origin iframes, run an actionability check
/// (attached, visible, enabled, receives pointer events), then dispatch the
/// full pointer/mouse event sequence so listeners on any stage fire. Returns a
/// JSON verdict; it never pretends an inert or hidden element was clicked.
enum WebActivationScript {
    /// Builds the script for one selector chain (JSON-encoded to survive quoting).
    static func script(forSelectorChain chain: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [chain]),
              let encoded = String(data: data, encoding: .utf8) else { return nil }
        // encoded is a one-element JSON array: ["<chain>"]
        return """
        (function() {
          var chain = \(encoded)[0];
          function resolve(chain) {
            var parts = chain.split(" >>> ");
            var root = document;
            var el = null;
            for (var i = 0; i < parts.length; i++) {
              el = root.querySelector(parts[i]);
              if (!el) return null;
              if (i < parts.length - 1) {
                var next = el.shadowRoot;
                if (!next) { try { next = el.contentDocument; } catch (e) { next = null; } }
                if (!next) return null;
                root = next;
              }
            }
            return el;
          }
          var el = resolve(chain);
          if (!el) return JSON.stringify({ matched: false, activated: false, reason: "no_match" });
          var win = (el.ownerDocument && el.ownerDocument.defaultView) || window;
          var style = win.getComputedStyle(el);
          var rect = el.getBoundingClientRect();
          if (!el.isConnected || !style || style.display === "none" || style.visibility === "hidden"
              || rect.width <= 0 || rect.height <= 0) {
            return JSON.stringify({ matched: true, activated: false, reason: "not_visible" });
          }
          if (el.disabled || el.getAttribute("aria-disabled") === "true") {
            return JSON.stringify({ matched: true, activated: false, reason: "disabled" });
          }
          if (style.pointerEvents === "none") {
            return JSON.stringify({ matched: true, activated: false, reason: "pointer_events_none" });
          }
          try { if (el.focus) el.focus(); } catch (e) {}
          var cx = rect.left + rect.width / 2;
          var cy = rect.top + rect.height / 2;
          var sequence = ["pointerdown", "mousedown", "pointerup", "mouseup", "click"];
          for (var i = 0; i < sequence.length; i++) {
            var type = sequence[i];
            var Ctor = (type.indexOf("pointer") === 0 && win.PointerEvent) ? win.PointerEvent : win.MouseEvent;
            el.dispatchEvent(new Ctor(type, {
              bubbles: true, cancelable: true, composed: true, view: win,
              button: 0, buttons: type.indexOf("down") >= 0 ? 1 : 0,
              clientX: cx, clientY: cy
            }));
          }
          return JSON.stringify({ matched: true, activated: true, tag: el.tagName.toLowerCase() });
        })();
        """
    }
}
