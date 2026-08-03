package dev.reticle.core

/**
 * The read-only DOM traversal script both WebView bridges run.
 *
 * The JavaScript itself lives ONCE, in `reticle-protocol/scripts/dom-traversal.js`,
 * and is embedded here and in `ReticleProtocol.WebViewDomScript` verbatim. It used
 * to be hand-copied between the Android agent and the iOS agent under a
 * "KEEP IN SYNC" comment — with different escaping on each side, so the two copies
 * could not even be diffed mechanically. `WebViewDomScriptTest` (Kotlin) and
 * `WebViewDomScriptTests` (Swift) each assert their embedded copy equals that file,
 * so an edit to one embedding, or to the file, fails the build until all three
 * agree.
 *
 * The script is embedded rather than loaded at runtime on purpose: the Android
 * agent also ships as a payload dex pushed into a live process by `app inject`,
 * which carries no resources.
 *
 * What it does: walks the visible DOM without mutating page state, pierces OPEN
 * shadow roots and same-origin iframes (Playwright's injected-script approach) —
 * pierced elements carry a chained selector (`#host >>> #inner`) and iframe
 * content coordinates are offset into page space — and folds DOM rectangles into
 * page coordinates the host then maps to the screen.
 */
object WebViewDomScript {
    val SCRIPT: String = """
        (function() {
          var MAX = 300;
          var count = 0;
          function clean(value, max) {
            if (value == null) return "";
            return String(value).replace(/\s+/g, " ").trim().slice(0, max || 160);
          }
          function cssEscape(value) {
            if (window.CSS && CSS.escape) return CSS.escape(value);
            return String(value).replace(/[^a-zA-Z0-9_-]/g, "\\$&");
          }
          function selectorFor(el) {
            if (el.id) return "#" + cssEscape(el.id);
            var parts = [];
            var current = el;
            // Stop at the element's OWN document root (which may be an iframe's,
            // not the top document's).
            while (current && current.nodeType === 1 && current !== current.ownerDocument.documentElement) {
              var part = current.tagName.toLowerCase();
              if (current.classList && current.classList.length) {
                part += "." + Array.prototype.slice.call(current.classList, 0, 2).map(cssEscape).join(".");
              }
              var sibling = current;
              var index = 1;
              while ((sibling = sibling.previousElementSibling) != null) {
                if (sibling.tagName === current.tagName) index++;
              }
              part += ":nth-of-type(" + index + ")";
              parts.unshift(part);
              current = current.parentElement;
            }
            return parts.join(" > ");
          }
          // An <input>'s type IS its role. Reading every input as a text field was
          // measured turning a bank consent checkbox into `role: textField` while
          // `domInputType` sat right beside it saying `checkbox` — the fact was
          // captured and then thrown away by the mapping.
          var INPUT_ROLES = {
            checkbox: "checkbox",
            radio: "radio",
            submit: "button",
            button: "button",
            reset: "button",
            image: "button",
            range: "slider",
            color: "colorPicker",
            file: "filePicker"
          };
          function roleFor(el) {
            var explicit = clean(el.getAttribute("role"), 40);
            if (explicit) return explicit;
            var tag = el.tagName.toLowerCase();
            if (tag === "a") return "link";
            if (tag === "button") return "button";
            if (tag === "input") {
              var type = clean(el.getAttribute("type"), 40).toLowerCase();
              return INPUT_ROLES[type] || "textField";
            }
            if (tag === "textarea") return "textField";
            if (tag === "select") return "picker";
            if (/^h[1-6]$/.test(tag)) return "heading";
            return tag;
          }
          // A field's VALUE only. Placeholder used to be folded in here as a fallback,
          // which made an empty field and a filled one project identically — and made
          // `act type`'s read-back structurally unable to tell whether text landed
          // (`dom-input-value-not-separable-from-placeholder`). It is its own key now.
          function textFor(el) {
            var tag = el.tagName.toLowerCase();
            if (tag === "body" || tag === "html") return "";
            if (tag === "input" || tag === "textarea") return clean(el.value, 160);
            return clean(el.innerText || el.textContent, 160);
          }
          // The accessible name, in the order a screen reader resolves it. A form built
          // out of framework components often sets NONE of id / data-testid / value, and
          // then the label is the only thing that tells five identical text fields apart.
          function nameFor(el) {
            var label = clean(el.getAttribute("aria-label"), 160);
            if (label) return label;
            var referenced = textOfReferenced(el, "aria-labelledby");
            if (referenced) return referenced;
            return clean(el.getAttribute("title") || el.getAttribute("alt"), 160);
          }
          function textOfReferenced(el, attribute) {
            var ids = clean(el.getAttribute(attribute), 200);
            if (!ids) return "";
            var doc = el.ownerDocument || document;
            var parts = [];
            ids.split(/\s+/).forEach(function(id) {
              var target = null;
              try { target = doc.getElementById(id); } catch (e) { target = null; }
              if (target) parts.push(clean(target.innerText || target.textContent, 160));
            });
            return clean(parts.join(" "), 160);
          }
          // Tri-state on purpose: "" means this element is not checkable at all, which
          // is a different fact from "checkable and off". Only the second is a state an
          // agent may act on.
          function checkedFor(el) {
            var tag = el.tagName.toLowerCase();
            var type = clean(el.getAttribute("type"), 40).toLowerCase();
            if (tag === "input" && (type === "checkbox" || type === "radio")) {
              return el.checked ? "true" : "false";
            }
            var aria = clean(el.getAttribute("aria-checked"), 40).toLowerCase();
            if (aria === "true" || aria === "false" || aria === "mixed") return aria;
            var pressed = clean(el.getAttribute("aria-pressed"), 40).toLowerCase();
            if (pressed === "true" || pressed === "false") return pressed;
            if (tag === "option") return el.selected ? "true" : "false";
            return "";
          }
          function interactive(el) {
            var tag = el.tagName.toLowerCase();
            if (/^(a|button|input|select|textarea|summary)$/.test(tag)) return true;
            var role = clean(el.getAttribute("role"), 40);
            if (/^(button|link|checkbox|radio|tab|switch|menuitem)$/.test(role)) return true;
            if (el.hasAttribute("onclick") || el.tabIndex >= 0) return true;
            return el.getAttribute("contenteditable") === "true";
          }
          function styleValue(style, key, max) {
            return clean(style ? style[key] : "", max || 40);
          }
          // prefix: the " >>> " selector chain of the enclosing shadow host /
          // iframe (empty at the top document). offset: accumulated page offset
          // of the enclosing iframe viewport (0,0 at the top document).
          function chainFor(el, prefix) {
            var local = selectorFor(el);
            return prefix ? prefix + " >>> " + local : local;
          }
          function walk(el, prefix, offset) {
            if (!el || count >= MAX) return null;
            var win = (el.ownerDocument && el.ownerDocument.defaultView) || window;
            var style = win.getComputedStyle(el);
            if (!style || style.display === "none" || style.visibility === "hidden") return null;
            var rect = el.getBoundingClientRect();
            var left = rect.left + offset.x;
            var top = rect.top + offset.y;
            var chain = chainFor(el, prefix);
            var children = [];
            for (var i = 0; i < el.children.length && count < MAX; i++) {
              var child = walk(el.children[i], prefix, offset);
              if (child) children.push(child);
            }
            // Pierce an OPEN shadow root: same coordinate space as the host,
            // selectors chain through the host.
            if (el.shadowRoot) {
              for (var s = 0; s < el.shadowRoot.children.length && count < MAX; s++) {
                var shadowChild = walk(el.shadowRoot.children[s], chain, offset);
                if (shadowChild) children.push(shadowChild);
              }
            }
            // Pierce a same-origin iframe: content coordinates are relative to
            // the frame viewport, so accumulate the frame's page offset.
            // Cross-origin frames throw / return null — they stay opaque.
            var frameDoc = null;
            try { frameDoc = el.contentDocument; } catch (e) { frameDoc = null; }
            if (frameDoc && frameDoc.body) {
              var frameOffset = { x: left + el.clientLeft, y: top + el.clientTop };
              var frameBody = walk(frameDoc.body, chain, frameOffset);
              if (frameBody) children.push(frameBody);
            }
            var inViewport = rect.width > 0 && rect.height > 0 &&
              left + rect.width >= 0 && top + rect.height >= 0 &&
              left <= window.innerWidth && top <= window.innerHeight;
            if (!inViewport && children.length === 0) return null;
            count++;
            var id = clean(el.id, 120);
            var tag = el.tagName.toLowerCase();
            var image = tag === "img" ? el : null;
            return {
              tag: clean(tag, 40),
              id: id,
              className: clean(el.className, 160),
              selector: chain,
              testId: clean(el.getAttribute("data-testid") || el.getAttribute("data-test-id") || id, 120),
              role: roleFor(el),
              name: nameFor(el),
              text: textFor(el),
              placeholder: clean(el.getAttribute("placeholder"), 160),
              formName: clean(el.getAttribute("name"), 120),
              checked: checkedFor(el),
              // The field/error pairing a form states in markup. Without it an error
              // string is an ordinary sibling div and nothing says which input it is
              // about.
              invalid: el.getAttribute("aria-invalid") === "true",
              describedBy: textOfReferenced(el, "aria-describedby"),
              href: clean(el.getAttribute("href"), 200),
              src: clean(el.getAttribute("src"), 500),
              srcset: clean(el.getAttribute("srcset"), 500),
              sizes: clean(el.getAttribute("sizes"), 160),
              imageCurrentSrc: image ? clean(image.currentSrc || image.src, 500) : "",
              imageNaturalWidth: image ? image.naturalWidth || 0 : 0,
              imageNaturalHeight: image ? image.naturalHeight || 0 : 0,
              imageComplete: image ? !!image.complete : false,
              inputType: clean(el.getAttribute("type"), 40),
              disabled: !!el.disabled || el.getAttribute("aria-disabled") === "true",
              interactive: interactive(el),
              left: left + window.scrollX,
              top: top + window.scrollY,
              width: rect.width,
              height: rect.height,
              marginTop: styleValue(style, "marginTop"),
              marginRight: styleValue(style, "marginRight"),
              marginBottom: styleValue(style, "marginBottom"),
              marginLeft: styleValue(style, "marginLeft"),
              styleDisplay: styleValue(style, "display"),
              styleVisibility: styleValue(style, "visibility"),
              styleOpacity: styleValue(style, "opacity"),
              stylePosition: styleValue(style, "position"),
              styleZIndex: styleValue(style, "zIndex"),
              styleOverflowX: styleValue(style, "overflowX"),
              styleOverflowY: styleValue(style, "overflowY"),
              styleColor: styleValue(style, "color"),
              styleBackgroundColor: styleValue(style, "backgroundColor"),
              styleBackgroundImage: styleValue(style, "backgroundImage", 500),
              styleFontSize: styleValue(style, "fontSize"),
              styleFontWeight: styleValue(style, "fontWeight"),
              styleFontFamily: styleValue(style, "fontFamily"),
              styleLineHeight: styleValue(style, "lineHeight"),
              styleTextAlign: styleValue(style, "textAlign"),
              stylePaddingTop: styleValue(style, "paddingTop"),
              stylePaddingRight: styleValue(style, "paddingRight"),
              stylePaddingBottom: styleValue(style, "paddingBottom"),
              stylePaddingLeft: styleValue(style, "paddingLeft"),
              styleBorderTopWidth: styleValue(style, "borderTopWidth"),
              styleBorderRightWidth: styleValue(style, "borderRightWidth"),
              styleBorderBottomWidth: styleValue(style, "borderBottomWidth"),
              styleBorderLeftWidth: styleValue(style, "borderLeftWidth"),
              styleBorderRadius: styleValue(style, "borderRadius"),
              styleTransform: styleValue(style, "transform"),
              stylePointerEvents: styleValue(style, "pointerEvents"),
              children: children
            };
          }
          return JSON.stringify({
            viewportWidth: window.innerWidth || document.documentElement.clientWidth || 0,
            viewportHeight: window.innerHeight || document.documentElement.clientHeight || 0,
            scrollX: window.scrollX || window.pageXOffset || 0,
            scrollY: window.scrollY || window.pageYOffset || 0,
            root: walk(document.body || document.documentElement, "", { x: 0, y: 0 })
          });
        })();

    """.trimIndent()
}
