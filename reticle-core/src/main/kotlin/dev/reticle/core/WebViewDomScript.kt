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
          // Set when the walk stopped at MAX rather than at the end of the document. The
          // projection's own cap announces itself; this one used to stop silently, so a
          // partial tree read as the whole screen.
          var capped = false;
          // The last pointer that arrived in this page, recorded by `dom-pointer-witness.js`
          // (a separate script, because that one adds a listener and this one must stay a
          // read). Read here rather than in its own round trip so the ELEMENT can be compared
          // by identity against the element being captured: that is the only join between an
          // event target and a captured node that cannot drift — a second selector
          // implementation would be a third answer to "which node is this".
          //
          // Absent when nothing has been tapped, when the witness was never installed, or in
          // a per-frame evaluation whose parent window is sealed. `pointerSeen` distinguishes
          // "a touch arrived on an element in this tree" from "a touch arrived somewhere
          // else", which is the whole diagnostic value: a selector tap that reports
          // `settled=1` and lands 130px away is otherwise silent.
          var pointer = null;
          try { pointer = window.__reticlePointer || null; } catch (e) { pointer = null; }
          if (pointer && !pointer.ts) pointer = null;
          var pointerSeen = false;
          function clean(value, max) {
            if (value == null) return "";
            return String(value).replace(/\s+/g, " ").trim().slice(0, max || 160);
          }
          function cssEscape(value) {
            if (window.CSS && CSS.escape) return CSS.escape(value);
            return String(value).replace(/[^a-zA-Z0-9_-]/g, "\\$&");
          }
          // The element's 1-based position among its siblings, counting either every
          // element child (`nth-child`) or only those with its own tag (`nth-of-type`).
          //
          // Read HERE, in the page, and carried per node, because the captured tree is not
          // a faithful sibling list: the walk drops `display:none` / `visibility:hidden`
          // elements, so counting children of the captured parent would answer a
          // `:nth-of-type(3)` query with the third VISIBLE sibling. That is the shape of a
          // silently-wrong tap — the number would look plausible and point at the wrong
          // control — so the matcher uses these instead of counting.
          function siblingIndex(el, sameTagOnly) {
            var index = 1;
            var sibling = el;
            while ((sibling = sibling.previousElementSibling) != null) {
              if (!sameTagOnly || sibling.tagName === el.tagName) index++;
            }
            return index;
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
              part += ":nth-of-type(" + siblingIndex(current, true) + ")";
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
          function tagOf(el) {
            return el.tagName ? el.tagName.toLowerCase() : "";
          }
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
            var titled = clean(el.getAttribute("title") || el.getAttribute("alt"), 160);
            if (titled) return titled;
            return labelledName(el);
          }
          // The rest of the accessible-name order for a FORM CONTROL, which the
          // attributes above miss entirely for a framework-built form: `<label for>`,
          // an ancestor `<label>`, and — the shape measured on a real one — a `<label>`
          // that sits beside the input inside the field's own wrapper with no `for` at
          // all. Without this, five identical `textField` lines carried no name, the
          // field name was visible ONLY in a screenshot, and picking a field by its
          // position in the DOM put a city into the street box while `act type`
          // reported `textLanded=exact focusLanded=self`.
          //
          // Deliberately narrow, because a wrong name is worse than none: form
          // controls only, at most three wrapper levels up, and the level must hold
          // EXACTLY ONE label-ish element and no second form control — a fieldset
          // legend over a group of inputs names the group, not any one of them, and
          // two labels beside two inputs is a guess. `nameSource` says which rule
          // answered, so a heuristic name is never mistaken for a declared one.
          function isFormControl(el) {
            var tag = tagOf(el);
            return tag === "input" || tag === "textarea" || tag === "select";
          }
          // A control that can carry a field's name. Form controls, plus the shape a
          // component library uses for a select: a <button> (or a div declaring the
          // button role, or one declaring a popup / expanded state) that OPENS a list
          // and then displays the chosen value as its own text. Measured on a real
          // form: five such dropdowns projected as `button "<value>" collapsed` — five
          // values with nothing saying which field each one belonged to, so the only
          // way to tell was their order down the page.
          function isNameableControl(el) {
            if (isFormControl(el)) return true;
            if (tagOf(el) === "button") return true;
            var role = clean(el.getAttribute("role"), 40).toLowerCase();
            if (role === "button" || role === "combobox" || role === "listbox") return true;
            return el.hasAttribute("aria-expanded") || !!clean(el.getAttribute("aria-haspopup"), 40);
          }
          function labelledName(el) {
            if (!isNameableControl(el)) return "";
            var doc = el.ownerDocument || document;
            var id = clean(el.id, 120);
            if (id) {
              var explicit = null;
              try { explicit = doc.querySelector('label[for="' + id.replace(/"/g, '') + '"]'); }
              catch (e) { explicit = null; }
              if (explicit) {
                var forText = clean(explicit.innerText || explicit.textContent, 160);
                if (forText) return forText;
              }
            }
            var node = el.parentElement;
            for (var level = 0; node && level < 3; level++) {
              if (tagOf(node) === "label") {
                var ancestorText = clean(node.innerText || node.textContent, 160);
                if (ancestorText) return ancestorText;
              }
              var labels = node.querySelectorAll("label, legend");
              var controls = node.querySelectorAll("input, textarea, select, button, [role=button]");
              if (labels.length === 1 && controls.length === 1) {
                var nearby = clean(labels[0].innerText || labels[0].textContent, 160);
                if (nearby) return nearby;
              }
              node = node.parentElement;
            }
            return "";
          }
          // Which rule produced `name`, so the projection can stay honest about a name
          // that was inferred from layout rather than declared by the page.
          function nameSourceFor(el) {
            if (clean(el.getAttribute("aria-label"), 160)) return "aria-label";
            if (textOfReferenced(el, "aria-labelledby")) return "aria-labelledby";
            if (clean(el.getAttribute("title") || el.getAttribute("alt"), 160)) return "title";
            if (labelledName(el)) return "label";
            return "";
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
          // A click handler bound in JS is not readable from the page (getEventListeners
          // is a devtools API), so a control a component framework built out of divs
          // publishes no handler to find. What it DOES publish is these — and without them
          // an unopened dropdown is a label with no executable next step, which is the
          // single largest source of coordinate taps measured on a real form.
          function hasPopup(el) {
            var value = clean(el.getAttribute("aria-haspopup"), 40).toLowerCase();
            if (!value || value === "false") return "";
            // The attribute's bare form means "menu"; anything else names the popup.
            return value === "true" ? "menu" : value;
          }
          function interactive(el, pointerOrigin) {
            var tag = el.tagName.toLowerCase();
            if (/^(a|button|input|select|textarea|summary)$/.test(tag)) return true;
            var role = clean(el.getAttribute("role"), 40);
            // Widget roles that take a click. `combobox`/`option`/`treeitem` are how a
            // div-built select names itself, and were missing.
            if (/^(button|link|checkbox|radio|tab|switch|menuitem|combobox|option|treeitem|menuitemcheckbox|menuitemradio)$/.test(role)) return true;
            if (el.hasAttribute("onclick") || el.tabIndex >= 0) return true;
            // A control that declares it opens something is a control you can open.
            if (hasPopup(el)) return true;
            if (el.hasAttribute("aria-expanded")) return true;
            // Weakest of the signals and the only inferred one: the page telling a human
            // "this is clickable". Kept because a framework-built trigger often declares
            // nothing else — and confined to where the pointer STARTS, since `cursor` is
            // inherited and marking every descendant would turn one control into four.
            if (pointerOrigin) return true;
            return el.getAttribute("contenteditable") === "true";
          }
          // Is the caret in THIS element? `document.activeElement` (or the shadow root's,
          // for a pierced tree) is the page's own answer, and without it the DOM half of
          // the tree carried no focus at all: the platform focus sits on the host WebView
          // while the caret is in an input, so `act type` could only ever report
          // `focusLanded=ancestor` and its read-back had nothing to follow. Measured on a
          // real form, that is how text that plainly landed was reported unreadable.
          function focusedFor(el) {
            try {
              var root = el.getRootNode ? el.getRootNode() : (el.ownerDocument || document);
              if (root && root.activeElement === el) return true;
              var doc = el.ownerDocument || document;
              return doc.activeElement === el;
            } catch (e) {
              return false;
            }
          }
          function styleValue(style, key, max) {
            return clean(style ? style[key] : "", max || 40);
          }
          // prefix: the " >>> " selector chain of the enclosing shadow host /
          // iframe (empty at the top document).
          function chainFor(el, prefix) {
            var local = selectorFor(el);
            return prefix ? prefix + " >>> " + local : local;
          }
          // Everything about a frame element that the PARENT document may read — which
          // includes a frame whose own document it may not. Browser policy withholds the
          // document, not the element: attributes and `contentWindow.length` stay
          // readable, and those are what separate "a widget still loading", "a frame the
          // page itself sealed", and "another origin, forever".
          function frameFacts(el) {
            var facts = {
              doc: null,
              reason: "",
              name: clean(el.getAttribute("name"), 120),
              sandbox: clean(el.getAttribute("sandbox"), 200),
              allow: clean(el.getAttribute("allow"), 200),
              loading: clean(el.getAttribute("loading"), 40),
              url: "",
              readyState: "",
              childCount: -1
            };
            var hasSandbox = el.hasAttribute("sandbox");
            var sandboxTokens = facts.sandbox.toLowerCase().split(/\s+/);
            var sameOriginAllowed = !hasSandbox || sandboxTokens.indexOf("allow-same-origin") >= 0;
            // Readable across origins — the count of frames nested INSIDE this one. The
            // only fact available about the shape of a sealed subtree, and the difference
            // between "an empty wall" and "a wall with three more behind it".
            try {
              if (el.contentWindow) facts.childCount = el.contentWindow.length;
            } catch (e) {}
            var doc = null;
            try { doc = el.contentDocument; } catch (e) { doc = null; }
            if (doc) {
              facts.doc = doc;
              try { facts.url = clean(doc.URL, 500); } catch (e) {}
              try { facts.readyState = clean(doc.readyState, 40); } catch (e) {}
              // A frame with a pending `src` still answers with the placeholder
              // about:blank document it was created with: readable, and NOT the content
              // the page asked for. Reported as its own state, because retrying IS the
              // right move here and is exactly the wrong move for the two below.
              if (!doc.body || (facts.url === "about:blank" && clean(el.getAttribute("src"), 500))) {
                facts.reason = "not-loaded";
              }
            } else {
              // `contentDocument` either throws (Chrome) or returns null (some engines),
              // and both look exactly like "has not loaded yet" from outside — a caller
              // that cannot tell them apart retries, waits, then measures pixels off a
              // screenshot. WHICH wall it is matters too: a sandbox without
              // `allow-same-origin` is the page's own choice on a frame that may well be
              // same-site, so calling it cross-origin sent readers hunting a domain
              // problem that was never there.
              facts.reason = hasSandbox && !sameOriginAllowed ? "sandboxed" : "cross-origin";
            }
            return facts;
          }
          // This frame's index among its parent's `window.frames`. The handle a per-frame
          // evaluation is keyed by on BOTH sides — the frame-probe handshake walks
          // `window.frames` the same way — and the only identity a frame has that survives
          // an origin it may not read. -1 when even `contentWindow` was refused.
          function frameIndexOf(el) {
            try {
              var win = el.contentWindow;
              if (!win) return -1;
              var frames = (el.ownerDocument && el.ownerDocument.defaultView) || window;
              for (var i = 0; i < frames.length; i++) {
                if (frames[i] === win) return i;
              }
            } catch (e) {}
            return -1;
          }
          // How a frame's inner coordinates scale on the way out to the page. Two
          // independent factors, both previously ignored: a CSS transform on the frame
          // element (`t*`) and a frame viewport that differs from the element's content
          // box (`s*` folds both). A frame under `transform: scale(0.5)` — the shape a
          // responsive third-party widget ships in — therefore reported every child at
          // double size in the wrong place, silently and plausibly.
          function frameScale(el, rect) {
            var layoutW = el.offsetWidth || 0;
            var layoutH = el.offsetHeight || 0;
            var tx = layoutW > 0 ? rect.width / layoutW : 1;
            var ty = layoutH > 0 ? rect.height / layoutH : 1;
            var sx = tx;
            var sy = ty;
            var innerW = 0;
            var innerH = 0;
            try {
              var win = el.contentWindow;
              if (win) {
                innerW = win.innerWidth || 0;
                innerH = win.innerHeight || 0;
              }
            } catch (e) {}
            if (innerW > 0 && el.clientWidth > 0) sx = tx * (el.clientWidth / innerW);
            if (innerH > 0 && el.clientHeight > 0) sy = ty * (el.clientHeight / innerH);
            return { sx: sx, sy: sy, tx: tx, ty: ty };
          }
          // `matrix(a,b,c,d,e,f)`: a non-zero b or c is rotation or skew, so the content
          // inside is no longer axis-aligned and an (x,y,w,h) rect cannot describe it.
          // Said out loud rather than approximated in silence — the rect stays the
          // axis-aligned hull, which is what `getBoundingClientRect` gives.
          function skewed(style) {
            var t = styleValue(style, "transform", 200);
            if (!t || t === "none") return false;
            if (t.indexOf("matrix3d") === 0) return true;
            var m = /^matrix\(([^)]*)\)$/.exec(t);
            if (!m) return false;
            var p = m[1].split(",");
            return Math.abs(parseFloat(p[1]) || 0) > 0.001 || Math.abs(parseFloat(p[2]) || 0) > 0.001;
          }
          // A scroll port's own numbers, so "there is more content below" is a fact
          // instead of an inference from `overflow`. `doc` is set for a frame element:
          // a frame scrolls its OWN document, and the frame element is what a caller
          // can swipe — so the numbers belong on the frame node.
          function scrollPortOf(el, style, doc) {
            var target = null;
            if (doc) {
              target = doc.scrollingElement || doc.documentElement;
            } else {
              var ox = styleValue(style, "overflowX");
              var oy = styleValue(style, "overflowY");
              if ((ox && ox !== "visible") || (oy && oy !== "visible")) target = el;
            }
            if (!target) return null;
            return {
              scrollLeft: Math.round(target.scrollLeft || 0),
              scrollTop: Math.round(target.scrollTop || 0),
              scrollWidth: Math.round(target.scrollWidth || 0),
              scrollHeight: Math.round(target.scrollHeight || 0),
              clientWidth: Math.round(target.clientWidth || 0),
              clientHeight: Math.round(target.clientHeight || 0)
            };
          }
          // Intersection of every clipping ancestor's box, in the element's own document
          // coordinates. null = nothing clips this subtree.
          function intersect(a, b) {
            if (!a) return b;
            if (!b) return a;
            var left = Math.max(a.left, b.left);
            var top = Math.max(a.top, b.top);
            var right = Math.min(a.right, b.right);
            var bottom = Math.min(a.bottom, b.bottom);
            return { left: left, top: top, right: right, bottom: bottom };
          }
          // Fully outside its clip — not merely cut in half. Conservative on purpose: a
          // partially visible row is visible, and calling it hidden would be worse than
          // the problem being fixed.
          function outsideClip(rect, clip) {
            if (!clip) return false;
            if (rect.width <= 0 || rect.height <= 0) return false;
            return rect.right <= clip.left || rect.left >= clip.right ||
              rect.bottom <= clip.top || rect.top >= clip.bottom;
          }
          // ctx: how this element's document maps onto the page. `x`/`y` is the enclosing
          // frame viewport's page offset and `sx`/`sy` its accumulated scale (0,0,1,1 at
          // the top document); `approx` is set once a frame in the chain is rotated or
          // skewed, so a rect that can only be a hull says so.
          function walk(el, prefix, ctx, parentCursor, clip) {
            if (!el || count >= MAX) { if (el) capped = true; return null; }
            var win = (el.ownerDocument && el.ownerDocument.defaultView) || window;
            var style = win.getComputedStyle(el);
            if (!style || style.display === "none" || style.visibility === "hidden") return null;
            var cursor = styleValue(style, "cursor");
            // `cursor` is inherited, so a pointer on a wrapper computes as pointer on every
            // descendant. Only the node where it starts is the control.
            var pointerOrigin = cursor === "pointer" && parentCursor !== "pointer";
            var rect = el.getBoundingClientRect();
            // A `position: fixed` box is laid out against the viewport and is NOT clipped
            // by an ancestor's overflow — a CSS rule, not a guess.
            var ownClip = styleValue(style, "position") === "fixed" ? null : clip;
            var clipped = outsideClip(rect, ownClip);
            // This element clips its own children when it has a scroll port of any kind.
            var overflowX = styleValue(style, "overflowX");
            var overflowY = styleValue(style, "overflowY");
            var childClip = (overflowX && overflowX !== "visible") || (overflowY && overflowY !== "visible")
              ? intersect(ownClip, { left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom })
              : ownClip;
            var left = ctx.x + rect.left * ctx.sx;
            var top = ctx.y + rect.top * ctx.sy;
            var chain = chainFor(el, prefix);
            var children = [];
            for (var i = 0; i < el.children.length; i++) {
              // The budget check lives here rather than in the loop condition: as a
              // condition it short-circuits BEFORE `walk` is entered, so the walk never
              // learns it ran out and the cap stayed silent — which is the whole thing
              // this flag exists to stop.
              if (count >= MAX) { capped = true; break; }
              var child = walk(el.children[i], prefix, ctx, cursor, childClip);
              if (child) children.push(child);
            }
            // Pierce an OPEN shadow root: same coordinate space as the host,
            // selectors chain through the host.
            if (el.shadowRoot) {
              for (var s = 0; s < el.shadowRoot.children.length; s++) {
                if (count >= MAX) { capped = true; break; }
                var shadowChild = walk(el.shadowRoot.children[s], chain, ctx, cursor, childClip);
                if (shadowChild) children.push(shadowChild);
              }
            }
            // Pierce a same-origin iframe: content coordinates are relative to the frame
            // viewport and may be scaled on the way out, so accumulate both. Frames whose
            // document is withheld stay opaque and carry the reason (see frameFacts).
            var frame = tagOf(el) === "iframe" ? frameFacts(el) : null;
            if (frame && frame.doc && frame.doc.body) {
              var scale = frameScale(el, rect);
              var frameCtx = {
                // `clientLeft`/`clientTop` is the frame's border, in the PARENT's pixels:
                // scaled by the transform on the way out, but not by the frame's own
                // viewport factor, which applies only inside.
                x: left + el.clientLeft * ctx.sx * scale.tx,
                y: top + el.clientTop * ctx.sy * scale.ty,
                sx: ctx.sx * scale.sx,
                sy: ctx.sy * scale.sy,
                approx: ctx.approx || skewed(style)
              };
              var frameBody = walk(frame.doc.body, chain, frameCtx, cursor, null);
              if (frameBody) children.push(frameBody);
            }
            var scrollPort = scrollPortOf(el, style, frame ? frame.doc : null);
            // Pruned against the element's OWN viewport, not the top window's: `left`/`top`
            // are page space while a frame's content is laid out in the frame's, so the two
            // are only comparable in the document the element belongs to. This also prunes
            // content scrolled out of an inner frame, which the page-space comparison kept.
            var inViewport = rect.width > 0 && rect.height > 0 &&
              rect.left + rect.width >= 0 && rect.top + rect.height >= 0 &&
              rect.left <= (win.innerWidth || 0) && rect.top <= (win.innerHeight || 0);
            if (!inViewport && children.length === 0) return null;
            count++;
            var id = clean(el.id, 120);
            var tag = el.tagName.toLowerCase();
            var image = tag === "img" ? el : null;
            var pointerHit = !!(pointer && pointer.target && pointer.target === el);
            if (pointerHit) pointerSeen = true;
            return {
              tag: clean(tag, 40),
              id: id,
              className: clean(el.className, 160),
              selector: chain,
              testId: clean(el.getAttribute("data-testid") || el.getAttribute("data-test-id") || id, 120),
              role: roleFor(el),
              name: nameFor(el),
              nameSource: nameSourceFor(el),
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
              interactive: interactive(el, pointerOrigin),
              hasPopup: hasPopup(el),
              // "" when the element declares no expanded state at all — which is a
              // different fact from "closed", and the one that says this is not a
              // disclosure control.
              expanded: el.hasAttribute("aria-expanded")
                ? (clean(el.getAttribute("aria-expanded"), 40).toLowerCase() === "true" ? "true" : "false")
                : "",
              // Recorded only where it STARTS, and only as the weak signal it is: the page
              // said pointer, nothing declared a role.
              pointerOrigin: !!pointerOrigin,
              // THIS element is where the page's last pointer event actually landed. The
              // fact a tap has no other source for: everything else about a tap is what
              // Reticle intended, this is what the page received.
              pointerHit: pointerHit,
              // Page-truth sibling positions, so `:nth-of-type(n)` / `:nth-child(n)` can be
              // matched instead of refused. The captured path already carries the first one
              // per segment; these carry both as numbers for the element itself, which is
              // what a matcher needs when the caller edits or shortens that path.
              nthOfType: siblingIndex(el, true),
              nthChild: siblingIndex(el, false),
              // The caret's element, as the page reports it. See `focusedFor`.
              focused: focusedFor(el),
              // Laid out entirely outside a clipping ancestor's box: on screen in the
              // document's coordinates, and unseeable. `getComputedStyle` reports such an
              // element as perfectly ordinary — display and visibility are untouched — so
              // without this a 10-item counter strip puts nine unseeable digits into the
              // tree, where they poison `--label` and pad every projection.
              clipped: !!clipped,
              // A frame whose document this page may not read BY ORIGIN. Structural — no
              // wait or retry clears it — so it is stated rather than left as an empty
              // subtree. Kept as its own field because it is the oldest of these and
              // agents already read it.
              crossOriginFrame: frame ? frame.reason === "cross-origin" : false,
              // The full three-state answer for a frame with no children captured, and the
              // one that says what to DO: retry (`not-loaded`), stop and use coordinates
              // (`cross-origin`), or stop and fix the page (`sandboxed`). "" = this frame's
              // document was read, or this is not a frame.
              frameOpaque: frame ? frame.reason : "",
              // The frame's identity, all of it readable across origins. `frameChildCount`
              // is -1 when even that was refused; 0+ is how many frames are nested inside
              // — the only shape available for a sealed subtree.
              frameName: frame ? frame.name : "",
              frameUrl: frame ? frame.url : "",
              frameReadyState: frame ? frame.readyState : "",
              frameSandbox: frame ? frame.sandbox : "",
              frameAllow: frame ? frame.allow : "",
              frameLoading: frame ? frame.loading : "",
              frameChildCount: frame ? frame.childCount : -1,
              // What a PER-FRAME evaluation needs from this side to place its results: this
              // frame's index among `window.frames` (the handle both the fold and the
              // frame-probe handshake are keyed by), its content box in this document's
              // pixels, and the transform-only factor of its own scale. Emitted for every
              // frame, read only for the ones this document could not walk itself.
              frameIndex: frame ? frameIndexOf(el) : -1,
              frameClientLeft: frame ? el.clientLeft : -1,
              frameClientTop: frame ? el.clientTop : -1,
              frameClientWidth: frame ? el.clientWidth : -1,
              frameClientHeight: frame ? el.clientHeight : -1,
              frameScaleX: frame ? frameScale(el, rect).tx * ctx.sx : 0,
              frameScaleY: frame ? frameScale(el, rect).ty * ctx.sy : 0,
              frameSkewed: frame ? (ctx.approx || skewed(style)) : false,
              // Set when a frame in this element's chain is rotated or skewed: the rect is
              // the axis-aligned hull of the real box, so a tap at its centre may miss.
              geometryApprox: !!ctx.approx,
              // The scroll port's own numbers when this element has one (a frame element
              // carries its inner document's). The host turns these into the `scroll:`
              // capability; the raw numbers stay as the evidence behind it.
              scrollLeft: scrollPort ? scrollPort.scrollLeft : -1,
              scrollTop: scrollPort ? scrollPort.scrollTop : -1,
              scrollWidth: scrollPort ? scrollPort.scrollWidth : -1,
              scrollHeight: scrollPort ? scrollPort.scrollHeight : -1,
              scrollClientWidth: scrollPort ? scrollPort.clientWidth : -1,
              scrollClientHeight: scrollPort ? scrollPort.clientHeight : -1,
              // VIEWPORT coordinates, not page coordinates. These used to carry
              // `+ window.scrollX/Y` and the host folds subtracted the scroll again — a
              // round trip whose two halves were read at DIFFERENT times: every element's
              // rect during the walk, the scroll once after it. A page that scrolls or
              // reflows mid-walk therefore folded to rects offset by the delta, which is
              // silent (the tap dispatches at the reported centre and reports settled=1) and
              // was measured on a real page as roughly 130px. Viewport space needs no scroll
              // at all, so the two reads cannot disagree.
              left: left,
              top: top,
              // Scaled by the same accumulated frame factor as `left`/`top`: inside a
              // scaled frame the content's own pixels are not the page's.
              width: rect.width * ctx.sx,
              height: rect.height * ctx.sy,
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
          // The walk runs FIRST: object literals evaluate in source order, so reading
          // `capped` beside `root` would read it before the walk that sets it.
          // A PER-FRAME evaluation (the path into a frame whose document the page itself may
          // not read) passes its enclosing frame's fold in through `reticleFrameCtx`, and the
          // selector chain to prepend through `reticleFramePrefix`. Absent both, this is the
          // top document and the fold is the identity. Doing it this way keeps every line of
          // frame geometry in THIS file: the alternative was a second fold written in Swift
          // and a third in Kotlin, which is how the same rect gets three answers.
          var incoming = (typeof reticleFrameCtx === "object" && reticleFrameCtx) ? reticleFrameCtx : null;
          var prefix = (typeof reticleFramePrefix === "string") ? reticleFramePrefix : "";
          var rootCtx = { x: 0, y: 0, sx: 1, sy: 1, approx: false };
          if (incoming) {
            rootCtx.x = incoming.x || 0;
            rootCtx.y = incoming.y || 0;
            rootCtx.sx = incoming.sx || 1;
            rootCtx.sy = incoming.sy || 1;
            rootCtx.approx = !!incoming.approx;
            // The parent cannot read a foreign frame's viewport, so it sends the frame
            // element's CONTENT box and this side finishes the scale — the one factor of the
            // fold that only the inside knows.
            var innerW = window.innerWidth || 0;
            var innerH = window.innerHeight || 0;
            if (incoming.contentWidth > 0 && innerW > 0) rootCtx.sx = rootCtx.sx * (incoming.contentWidth / innerW);
            if (incoming.contentHeight > 0 && innerH > 0) rootCtx.sy = rootCtx.sy * (incoming.contentHeight / innerH);
          }
          var root = walk(document.body || document.documentElement, prefix, rootCtx, "", null);
          return JSON.stringify({
            viewportWidth: window.innerWidth || document.documentElement.clientWidth || 0,
            viewportHeight: window.innerHeight || document.documentElement.clientHeight || 0,
            // The page's scroll offset, reported as page STATE. It is deliberately NOT part
            // of the coordinate fold any more — see the `left`/`top` note above.
            scrollX: window.scrollX || window.pageXOffset || 0,
            scrollY: window.scrollY || window.pageYOffset || 0,
            capped: capped,
            captured: count,
            // The page's own account of the last touch it received: where it arrived in
            // VIEWPORT coordinates, how long ago, and whether its target is one of the
            // elements above. `pointerTs` being 0 means no touch has been witnessed at all,
            // which is a different fact from one that landed off-tree.
            pointerX: pointer ? pointer.x : 0,
            pointerY: pointer ? pointer.y : 0,
            pointerAgeMs: pointer ? Math.max(0, Date.now() - pointer.ts) : -1,
            pointerTs: pointer ? pointer.ts : 0,
            pointerMatched: pointerSeen,
            root: root
          });
        })();
    """.trimIndent()
}
