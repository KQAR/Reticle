import Foundation

/// JavaScript used by `WebTextInput` to type into a DOM field resolved by its
/// emitted `domCssSelector` chain — the web analogue of `act type`, and the twin
/// of `WebActivationScript`.
///
/// **Why a page-level path exists at all.** On Android a web field is typed like
/// any other: the text goes in through the platform IME, which the WebView sits
/// behind, so there is no DOM special case. iOS in-process has no IME to inject
/// into — `UIKeyInput.insertText` needs a responder, and a `WKWebView` does not
/// publish one (the object that implements text input is its private content
/// view, which the responder chain does not hand out). Measured on a real device:
/// a web field that `act tap --css` focuses, with the keyboard visibly up, still
/// answered `unsupported_text_target`. So for a DOM target the page itself is the
/// input surface.
///
/// **`execCommand('insertText')` first, on purpose.** It is the one path that
/// makes WebKit produce the same `beforeinput` / `input` sequence a keypress
/// does, which is what a framework binding (React, Vue) listens to. Assigning
/// `.value` fires nothing, so a field typed that way looks right on screen and
/// leaves the app's model empty — the exact class of silent lie this project
/// refuses. The assignment path is kept only as a stated fallback, through the
/// native setter so React's value tracker still notices, and it says which
/// route ran.
enum WebTextInputScript {
    /// Builds the script for one selector chain (JSON-encoded to survive quoting).
    /// `clear` empties the field first; `submit` presses Return afterwards.
    static func script(forSelectorChain chain: String, text: String, clear: Bool, submit: Bool) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [chain, text]),
              let encoded = String(data: data, encoding: .utf8) else { return nil }
        return """
        (function() {
          var args = \(encoded);
          var chain = args[0], text = args[1];
          var doClear = \(clear ? "true" : "false"), doSubmit = \(submit ? "true" : "false");
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
          if (!el) return JSON.stringify({ matched: false, typed: false, reason: "no_match" });

          // A selector legitimately names the WRAPPER of a field — that is what a
          // captured chain for a form row looks like — so accept an editable
          // descendant rather than refusing something the user plainly meant.
          function editable(node) {
            var tag = node.tagName ? node.tagName.toLowerCase() : "";
            if (tag === "input" || tag === "textarea") return true;
            return node.isContentEditable === true;
          }
          if (!editable(el)) {
            var inner = el.querySelector("input, textarea, [contenteditable=true], [contenteditable='']");
            if (inner) el = inner;
          }
          if (!editable(el)) {
            return JSON.stringify({ matched: true, typed: false, reason: "not_a_text_field",
                                    tag: el.tagName.toLowerCase() });
          }
          if (el.disabled || el.readOnly) {
            return JSON.stringify({ matched: true, typed: false, reason: el.disabled ? "disabled" : "readonly" });
          }
          var win = (el.ownerDocument && el.ownerDocument.defaultView) || window;
          var style = win.getComputedStyle(el);
          var rect = el.getBoundingClientRect();
          if (!el.isConnected || (style && style.visibility === "hidden")
              || (rect.width <= 0 && rect.height <= 0)) {
            return JSON.stringify({ matched: true, typed: false, reason: "not_visible" });
          }

          function read() {
            return el.value !== undefined && el.value !== null ? String(el.value) : String(el.textContent || "");
          }
          function selectAll() {
            if (el.setSelectionRange && el.value !== undefined) {
              try { el.setSelectionRange(0, el.value.length); return; } catch (e) {}
            }
            try {
              var range = el.ownerDocument.createRange();
              range.selectNodeContents(el);
              var sel = win.getSelection();
              sel.removeAllRanges();
              sel.addRange(range);
            } catch (e) {}
          }
          // Assignment through the NATIVE setter: React installs its own value
          // setter to track changes, and writing `el.value` directly hides the
          // change from it, so the component re-renders back to the old value.
          function assign(next) {
            try {
              var proto = Object.getPrototypeOf(el);
              var desc = Object.getOwnPropertyDescriptor(proto, "value");
              if (desc && desc.set) { desc.set.call(el, next); return true; }
            } catch (e) {}
            try { el.value = next; return true; } catch (e) {}
            return false;
          }
          function fire(type) {
            try { el.dispatchEvent(new win.Event(type, { bubbles: true, composed: true })); } catch (e) {}
          }

          var before = read();
          try { el.focus(); } catch (e) {}

          var via = "execCommand";
          if (doClear) {
            selectAll();
            var clearedByCommand = false;
            try { clearedByCommand = el.ownerDocument.execCommand("insertText", false, ""); } catch (e) {}
            if (!clearedByCommand || read().length > 0) {
              if (el.value !== undefined) { assign(""); fire("input"); }
              via = "assign";
            }
          }

          var ok = false;
          try { ok = el.ownerDocument.execCommand("insertText", false, text); } catch (e) { ok = false; }
          var afterCommand = read();
          if (!ok || afterCommand === before) {
            // execCommand is refused by some engines/fields; say so rather than
            // reporting a type that did not happen.
            if (el.value !== undefined) {
              assign(doClear ? text : (before + text));
              fire("input");
              fire("change");
              via = via === "assign" ? "assign" : "assign-fallback";
            }
          }

          if (doSubmit) {
            ["keydown", "keypress", "keyup"].forEach(function(type) {
              try {
                el.dispatchEvent(new win.KeyboardEvent(type, {
                  bubbles: true, cancelable: true, composed: true,
                  key: "Enter", code: "Enter", keyCode: 13, which: 13
                }));
              } catch (e) {}
            });
            try { if (el.form && el.form.requestSubmit) el.form.requestSubmit(); } catch (e) {}
          }

          return JSON.stringify({
            matched: true, typed: true, via: via, before: before, after: read(),
            tag: el.tagName.toLowerCase()
          });
        })();
        """
    }
}
