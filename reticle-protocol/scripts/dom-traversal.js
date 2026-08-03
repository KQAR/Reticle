(function() {
  var MAX = 300;
  var count = 0;
  // Set when the walk stopped at MAX rather than at the end of the document. The
  // projection's own cap announces itself; this one used to stop silently, so a
  // partial tree read as the whole screen.
  var capped = false;
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
  function walk(el, prefix, offset, parentCursor, clip) {
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
    var left = rect.left + offset.x;
    var top = rect.top + offset.y;
    var chain = chainFor(el, prefix);
    var children = [];
    for (var i = 0; i < el.children.length; i++) {
      // The budget check lives here rather than in the loop condition: as a
      // condition it short-circuits BEFORE `walk` is entered, so the walk never
      // learns it ran out and the cap stayed silent — which is the whole thing
      // this flag exists to stop.
      if (count >= MAX) { capped = true; break; }
      var child = walk(el.children[i], prefix, offset, cursor, childClip);
      if (child) children.push(child);
    }
    // Pierce an OPEN shadow root: same coordinate space as the host,
    // selectors chain through the host.
    if (el.shadowRoot) {
      for (var s = 0; s < el.shadowRoot.children.length; s++) {
        if (count >= MAX) { capped = true; break; }
        var shadowChild = walk(el.shadowRoot.children[s], chain, offset, cursor, childClip);
        if (shadowChild) children.push(shadowChild);
      }
    }
    // Pierce a same-origin iframe: content coordinates are relative to
    // the frame viewport, so accumulate the frame's page offset.
    // Cross-origin frames throw / return null — they stay opaque.
    var frameDoc = null;
    var crossOrigin = false;
    if (tagOf(el) === "iframe") {
      try {
        frameDoc = el.contentDocument;
      } catch (e) {
        frameDoc = null;
      }
      // Reached only for a frame: `contentDocument` either throws (Chrome) or
      // returns null (some engines) when the origin differs, and both look exactly
      // like "the frame has not loaded yet" from the outside. A caller with no way
      // to tell those apart retries, waits, and eventually measures pixels off a
      // screenshot — which is what a third-party payment/bank widget costs today.
      if (!frameDoc) crossOrigin = true;
    }
    if (frameDoc && frameDoc.body) {
      var frameOffset = { x: left + el.clientLeft, y: top + el.clientTop };
      var frameBody = walk(frameDoc.body, chain, frameOffset, cursor, null);
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
      // Laid out entirely outside a clipping ancestor's box: on screen in the
      // document's coordinates, and unseeable. `getComputedStyle` reports such an
      // element as perfectly ordinary — display and visibility are untouched — so
      // without this a 10-item counter strip puts nine unseeable digits into the
      // tree, where they poison `--label` and pad every projection.
      clipped: !!clipped,
      // A frame whose document this page may not read. Structural — no wait or
      // retry clears it — so it is stated rather than left as an empty subtree.
      crossOriginFrame: !!crossOrigin,
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
  // The walk runs FIRST: object literals evaluate in source order, so reading
  // `capped` beside `root` would read it before the walk that sets it.
  var root = walk(document.body || document.documentElement, "", { x: 0, y: 0 }, "", null);
  return JSON.stringify({
    viewportWidth: window.innerWidth || document.documentElement.clientWidth || 0,
    viewportHeight: window.innerHeight || document.documentElement.clientHeight || 0,
    scrollX: window.scrollX || window.pageXOffset || 0,
    scrollY: window.scrollY || window.pageYOffset || 0,
    capped: capped,
    captured: count,
    root: root
  });
})();

