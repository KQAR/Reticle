package dev.reticle.agent

import android.os.Handler
import android.os.Looper
import android.webkit.WebView
import dev.reticle.core.CheckedState
import dev.reticle.core.DomScroll
import dev.reticle.core.MetadataValue
import dev.reticle.core.Node
import dev.reticle.core.NodeKind
import dev.reticle.core.Rect
import dev.reticle.core.StyleChannel
import dev.reticle.core.WebPointerWitnessScript
import dev.reticle.core.WebViewDomScript
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Read-only WebView DOM bridge.
 *
 * The DOM is reached through WebView.evaluateJavascript(), which is asynchronous
 * and must run on the UI thread. SnapshotCapture first records WebView hosts
 * during the normal main-thread view walk, then this bridge posts DOM reads back
 * to the main thread while the caller waits off-thread with a short timeout.
 */
object WebViewBridge {
    private const val TIMEOUT_MS = 750L

    /** Marker for "the DOM could not be read from this WebView right now". */
    const val DOM_STATUS_KEY = "domStatus"
    const val DOM_STATUS_UNAVAILABLE = "unavailable"

    data class Pending(
        val webView: WebView,
        val parentRef: String,
        val webViewFrame: Rect,
    )

    fun captureInto(
        pending: List<Pending>,
        density: Double,
        handler: Handler,
        nodes: MutableMap<String, Node>,
        makeRef: () -> String,
    ) {
        if (pending.isEmpty() || Looper.myLooper() == Looper.getMainLooper()) return
        for (capture in pending) {
            val walk = captureOne(capture, density, handler, nodes, makeRef)
            val refs = walk.refs
            val parent = nodes[capture.parentRef] ?: continue
            if (refs.isEmpty()) {
                // Say so, rather than leaving an absence to be interpreted. A DOM
                // read fails for reasons an agent must be able to tell apart from
                // "this WebView has no content": a `alert()`/`confirm()` modal
                // blocks the page's JS thread so `evaluateJavascript` can never
                // call back, JS may be disabled, or the read may simply have
                // outrun its budget while the page animates. All of those look
                // identical — an opaque node — unless the node carries the fact.
                nodes[capture.parentRef] = parent.copy(
                    custom = parent.custom + mapOf(DOM_STATUS_KEY to MetadataValue.Text(DOM_STATUS_UNAVAILABLE)),
                )
                continue
            }
            // The traversal's own node cap, said out loud. The projection's cap
            // already announces itself; this one stopped silently, so a partial DOM
            // read as the whole page.
            val extra = if (walk.capped) {
                mapOf(
                    DOM_CAPPED_KEY to MetadataValue.Bool(true),
                    DOM_CAPTURED_KEY to MetadataValue.Integer(walk.captured),
                )
            } else {
                emptyMap()
            }
            nodes[capture.parentRef] = parent.copy(
                children = parent.children + refs,
                custom = parent.custom + extra + walk.pointer,
            )
        }
    }

    /** Set on a web view host whose DOM walk stopped at the traversal cap. */
    const val DOM_CAPPED_KEY = "domCapped"

    /** How many DOM nodes were captured before that cap was reached. */
    const val DOM_CAPTURED_KEY = "domCaptured"

    /** One web view's DOM walk: what it produced, and whether it ran out of budget. */
    private data class Walk(
        val refs: List<String>,
        val capped: Boolean = false,
        val captured: Long = 0L,
        /** The page's own account of the last touch it received, for the host node. */
        val pointer: Map<String, MetadataValue> = emptyMap(),
    )

    /**
     * The page's record of the last pointer that arrived, as host-node metadata.
     *
     * Empty when the page has witnessed no touch at all — which is a different fact
     * from a touch that landed off-tree (`domPointerMatched=false`), and the pair is
     * what makes a missed selector tap visible instead of silent. See [DomTapWitness].
     */
    private fun pointerFacts(json: JSONObject): Map<String, MetadataValue> {
        val ts = json.optLong("pointerTs", 0L)
        if (ts <= 0L) return emptyMap()
        return mapOf(
            "domPointerX" to MetadataValue.Integer(json.optLong("pointerX")),
            "domPointerY" to MetadataValue.Integer(json.optLong("pointerY")),
            "domPointerAgeMs" to MetadataValue.Integer(json.optLong("pointerAgeMs")),
            "domPointerMatched" to MetadataValue.Bool(json.optBoolean("pointerMatched", false)),
        )
    }

    private fun captureOne(
        pending: Pending,
        density: Double,
        handler: Handler,
        nodes: MutableMap<String, Node>,
        makeRef: () -> String,
    ): Walk {
        val encoded = evaluateDomScript(pending.webView, handler) ?: return Walk(emptyList())
        val payload = decodeJavascriptString(encoded) ?: return Walk(emptyList())
        val json = runCatching { JSONObject(payload) }.getOrNull() ?: return Walk(emptyList())
        val root = json.optJSONObject("root") ?: return Walk(emptyList())
        // Frames whose document the page may not read are walked IN THEIR OWN context
        // and spliced into this JSON before any node is built, so a control read that
        // way is an ordinary DOM node. Only paid for on a screen that has such a frame.
        if (hasOpaqueFrame(root)) spliceFrames(root, pending.webView, handler)
        val fold = CoordinateFold.from(json, pending.webViewFrame, density)
        val ref = visit(root, pending.parentRef, fold, nodes, makeRef)
        return Walk(
            refs = ref?.let { listOf(it) } ?: emptyList(),
            capped = json.optBoolean("capped", false),
            captured = json.optLong("captured"),
            pointer = pointerFacts(json),
        )
    }

    private fun evaluateDomScript(webView: WebView, handler: Handler): String? {
        val latch = CountDownLatch(1)
        var result: String? = null
        val posted = handler.post {
            try {
                if (!webView.isAttachedToWindow || !webView.settings.javaScriptEnabled) {
                    latch.countDown()
                    return@post
                }
                // Installed on every capture, idempotently, so the listener is in the
                // page before the NEXT gesture — a capture cannot witness the touch
                // that has not happened yet, and a page that navigated dropped the
                // one it had. Fire and forget: the traversal below reads whatever
                // record already exists, and these run in order on the JS thread.
                webView.evaluateJavascript(WebPointerWitnessScript.SCRIPT) { _ -> }
                webView.evaluateJavascript(WebViewDomScript.SCRIPT) { value ->
                    result = value
                    latch.countDown()
                }
                return@post
            } catch (_: Throwable) {
                // Honest L0 fallback: keep the WebView as an opaque view node.
            }
            latch.countDown()
        }
        if (!posted) return null
        if (!latch.await(TIMEOUT_MS, TimeUnit.MILLISECONDS)) return null
        return result
    }

    private fun decodeJavascriptString(encoded: String): String? {
        if (encoded == "null") return null
        return runCatching {
            JSONObject("{\"value\":$encoded}").optString("value").nullIfBlank()
        }.getOrNull()
    }

    /**
     * Is there a frame here whose document the page itself could not walk? Asked before
     * anything else: the per-frame path costs a JS round trip per frame, and the
     * overwhelming majority of pages have no such frame.
     */
    private fun hasOpaqueFrame(node: JSONObject): Boolean {
        if (node.optString("frameOpaque").isNotBlank()) return true
        val children = node.optJSONArray("children") ?: return false
        for (i in 0 until children.length()) {
            val child = children.optJSONObject(i) ?: continue
            if (hasOpaqueFrame(child)) return true
        }
        return false
    }

    /**
     * Walk every readable-but-sealed frame in its own context and splice the result
     * under the frame element, in the raw traversal JSON.
     *
     * The geometry is NOT recomputed here: the enclosing frame's fold is handed to the
     * traversal script through `reticleFrameCtx`, exactly as the iOS twin does it, so
     * every line of frame geometry stays in dom-traversal.js. A second copy in Kotlin
     * and a third in Swift is how one rect gets three answers.
     *
     * One round per depth level, because a frame's own children are only known once it
     * has answered — and a nested frame is addressed directly (`window.frames[i]
     * .frames[j]`), so no forwarding chain is involved.
     */
    private fun spliceFrames(root: JSONObject, webView: WebView, handler: Handler) {
        val unavailable = WebFrameBridge.unavailableReason()
        if (unavailable != null) {
            // WHICH half is missing, on the node: an app that needs a dependency, a
            // device that needs a newer WebView, and a call of ours that is wrong are
            // three different situations, and only the last one is a Reticle bug.
            markOpaque(root, WebFrameBridge.PROBE_UNAVAILABLE, unavailable)
            return
        }
        var budget = WebFrameBridge.FRAME_BUDGET
        var level = listOf("" to root)
        var depth = 0
        while (depth < WebFrameBridge.DEPTH_BUDGET && level.isNotEmpty()) {
            val requests = ArrayList<WebFrameBridge.Request>()
            val frameNodes = HashMap<String, JSONObject>()
            for ((prefix, subtree) in level) {
                budget = collectOpaque(subtree, prefix, budget, requests, frameNodes)
            }
            if (requests.isEmpty()) return
            val payloads = WebFrameBridge.read(webView, requests, handler)
            val next = ArrayList<Pair<String, JSONObject>>()
            for (request in requests) {
                val node = frameNodes[request.path] ?: continue
                val payload = payloads[request.path]
                if (payload == null) {
                    // No probe answered: the document loaded before the injection was
                    // registered, or the frame cannot script at all. Stated, not guessed
                    // — and NOT fixed by reloading the app's page from here.
                    node.put("frameProbe", WebFrameBridge.PROBE_NEEDS_RELOAD)
                    continue
                }
                val childRoot = runCatching { JSONObject(payload).optJSONObject("root") }.getOrNull()
                if (childRoot == null) {
                    node.put("frameProbe", WebFrameBridge.PROBE_FAILED)
                    continue
                }
                node.append("children", childRoot)
                // The wall is no longer a wall. Leaving the marker would tell a caller
                // coordinates are the only way in while a selector now resolves — and
                // ScreenCoverage reads the same fields.
                node.put("frameOpaque", "")
                node.put("crossOriginFrame", false)
                node.put("framePierced", "per-frame")
                next.add(request.path to childRoot)
            }
            level = next
            depth++
        }
        // Past the depth allowance: what was dropped says so rather than reading as an
        // empty frame.
        for ((_, subtree) in level) markOpaque(subtree, WebFrameBridge.PROBE_DEPTH_BUDGET)
    }

    /** Collects one level's sealed frames, marking the ones this capture cannot afford. */
    private fun collectOpaque(
        node: JSONObject,
        prefix: String,
        budgetIn: Int,
        requests: MutableList<WebFrameBridge.Request>,
        frameNodes: MutableMap<String, JSONObject>,
    ): Int {
        var budget = budgetIn
        if (node.optString("frameOpaque").isNotBlank()) {
            val index = node.optInt("frameIndex", -1)
            when {
                // No index means `contentWindow` itself was refused, so the frame has no
                // identity to address it by — there is nothing to ask.
                index < 0 -> node.put("frameProbe", WebFrameBridge.PROBE_NO_HANDLE)
                budget <= 0 -> node.put("frameProbe", WebFrameBridge.PROBE_BUDGET)
                else -> {
                    budget -= 1
                    val path = if (prefix.isEmpty()) "$index" else "$prefix/$index"
                    val chain = node.optString("selector")
                    requests.add(WebFrameBridge.Request(path, frameContext(node), chain))
                    frameNodes[path] = node
                }
            }
        }
        val children = node.optJSONArray("children") ?: return budget
        for (i in 0 until children.length()) {
            val child = children.optJSONObject(i) ?: continue
            // Siblings and descendants in the SAME document keep this document's path: a
            // path identifies a frame, not an element.
            budget = collectOpaque(child, prefix, budget, requests, frameNodes)
        }
        return budget
    }

    /** The fold a frame's own walk needs from this side. Mirrors `frameScript` on iOS. */
    private fun frameContext(node: JSONObject): JSONObject {
        val scaleX = node.optDouble("frameScaleX", 1.0).let { if (it == 0.0) 1.0 else it }
        val scaleY = node.optDouble("frameScaleY", 1.0).let { if (it == 0.0) 1.0 else it }
        return JSONObject()
            // The frame's border is in the PARENT's pixels, so it takes the transform
            // factor (already folded into frameScale*) and not the frame's own viewport
            // factor, which applies only inside.
            .put("x", node.optDouble("left", 0.0) + node.optDouble("frameClientLeft", 0.0) * scaleX)
            .put("y", node.optDouble("top", 0.0) + node.optDouble("frameClientTop", 0.0) * scaleY)
            .put("sx", scaleX)
            .put("sy", scaleY)
            .put("approx", node.optBoolean("frameSkewed", false))
            // The parent cannot read a foreign frame's viewport; the inside finishes the
            // scale from these.
            .put("contentWidth", node.optDouble("frameClientWidth", -1.0))
            .put("contentHeight", node.optDouble("frameClientHeight", -1.0))
    }

    /** Marks every still-sealed frame in this subtree with one mechanism reason. */
    private fun markOpaque(node: JSONObject, reason: String, detail: String? = null) {
        if (node.optString("frameOpaque").isNotBlank() && node.optString("frameProbe").isBlank()) {
            node.put("frameProbe", reason)
            if (detail != null) node.put("frameProbeDetail", detail)
        }
        val children = node.optJSONArray("children") ?: return
        for (i in 0 until children.length()) {
            val child = children.optJSONObject(i) ?: continue
            markOpaque(child, reason, detail)
        }
    }

    private fun visit(
        element: JSONObject,
        parentRef: String,
        fold: CoordinateFold,
        nodes: MutableMap<String, Node>,
        makeRef: () -> String,
    ): String? {
        val ref = makeRef()
        val childRefs = ArrayList<String>()
        element.optJSONArray("children").forEachObject { child ->
            visit(child, ref, fold, nodes, makeRef)?.let(childRefs::add)
        }

        val tag = element.optString("tag").lowercase()
        val role = element.optString("role").nullIfBlank() ?: tag.ifBlank { "dom" }
        val selector = element.optString("selector").nullIfBlank()
        val testId = element.optString("testId").nullIfBlank()
        val disabled = element.optBoolean("disabled", false)
        // Laid out entirely outside a clipping ancestor's box. Not visible, in the
        // plain sense: `compact` omits it, the semantic tree keeps it, and it stops
        // padding projections and poisoning `--label` — the same treatment every
        // other invisible node already gets.
        val clipped = element.optBoolean("clipped", false)
        val frame = fold.rectFor(element)

        val metadata = metadataFor(element, selector, fold)
        nodes[ref] = Node(
            ref = ref,
            parentRef = parentRef,
            kind = NodeKind.domNode,
            typeName = "DOMElement",
            role = role,
            contentDescription = element.optString("name").nullIfBlank(),
            text = element.optString("text").nullIfBlank(),
            testId = testId,
            frame = frame,
            isVisible = frame.width > 0.0 && frame.height > 0.0 && !clipped,
            isEnabled = !disabled,
            isInteractive = !disabled && element.optBoolean("interactive", false),
            // `document.activeElement`, as the page reported it. The platform focus
            // sits on the host WebView while the caret is in an input, so without
            // this the DOM half of the tree had no focus channel at all — `type`
            // could only say `focusLanded=ancestor`, and its read-back had no way to
            // find the field the text actually went into.
            isFocused = element.optBoolean("focused", false),
            // The DOM's own scroll port, published as the capability a native
            // container publishes — a pane (or a frame, which scrolls its own
            // document) that can still move now says so.
            scroll = scrollInfoFor(element),
            checked = checkedStateOf(element.optString("checked")),
            expanded = when (element.optString("expanded")) {
                "true" -> true
                "false" -> false
                else -> null
            },
            custom = metadata,
            // Computed CSS is the DOM's style channel. The values keep their own
            // suffixes ("14px", "1.5") and are NOT converted: a page's zoom and
            // viewport scaling are not observable from here, so a px->dp division
            // would be arithmetic on an assumption. The projection passes them
            // through verbatim (StyleUnit.opaque).
            styleChannels = metadata.keys
                .filter { it.startsWith("domStyle") }
                .associateWith { StyleChannel.computedStyle },
            children = childRefs,
        )
        return ref
    }

    /**
     * The scroll numbers the traversal read from this element's scroll port, or
     * null when it has none. The rule lives in [DomScroll] (with a Swift twin), not
     * here, so both platforms answer alike.
     */
    private fun scrollInfoFor(element: JSONObject): dev.reticle.core.ScrollInfo? =
        DomScroll.fromMetrics(
            scrollLeft = element.optDouble("scrollLeft", -1.0),
            scrollTop = element.optDouble("scrollTop", -1.0),
            scrollWidth = element.optDouble("scrollWidth", -1.0),
            scrollHeight = element.optDouble("scrollHeight", -1.0),
            clientWidth = element.optDouble("scrollClientWidth", -1.0),
            clientHeight = element.optDouble("scrollClientHeight", -1.0),
        )

    /**
     * The script reports a tri-state as a string so an absent third state stays
     * absent on the wire ("" = not a checkable control). Anything unrecognised
     * maps to null for the same reason: a value nobody understands is not
     * evidence that a box is unticked.
     */
    private fun checkedStateOf(raw: String?): CheckedState? = when (raw) {
        "true" -> CheckedState.on
        "false" -> CheckedState.off
        "mixed" -> CheckedState.mixed
        else -> null
    }

    private fun metadataFor(
        element: JSONObject,
        selector: String?,
        fold: CoordinateFold,
    ): Map<String, MetadataValue> {
        val map = LinkedHashMap<String, MetadataValue>()
        fun putText(key: String, value: String?) {
            value?.nullIfBlank()?.let { map[key] = MetadataValue.Text(it) }
        }
        fun putInteger(key: String, elementKey: String) {
            if (element.has(elementKey)) map[key] = MetadataValue.Integer(element.optLong(elementKey))
        }
        fun putBool(key: String, elementKey: String) {
            if (element.has(elementKey)) map[key] = MetadataValue.Bool(element.optBoolean(elementKey))
        }
        val tag = element.optString("tag")
        putText("domTag", tag)
        putText("domId", element.optString("id"))
        putText("domClass", element.optString("className"))
        putText("domCssSelector", selector)
        putText("domHref", element.optString("href"))
        putText("domSrc", element.optString("src"))
        putText("domSrcset", element.optString("srcset"))
        putText("domSizes", element.optString("sizes"))
        if (tag == "img") {
            putText("domImageCurrentSrc", element.optString("imageCurrentSrc"))
            putInteger("domImageNaturalWidth", "imageNaturalWidth")
            putInteger("domImageNaturalHeight", "imageNaturalHeight")
            putBool("domImageComplete", "imageComplete")
        }
        putText("domInputType", element.optString("inputType"))
        // The semantic handles a component-framework form actually carries. A
        // page whose inputs set no id and no value projects five identical
        // `textField` lines without these; the placeholder is usually the only
        // thing that says which one is the email field.
        if (element.optBoolean("clipped", false)) map["domClipped"] = MetadataValue.Bool(true)
        // Where the page's last touch actually landed. Set on ONE element per capture
        // at most, and the only fact about a tap that does not come from Reticle's own
        // arithmetic — see [WebPointerWitnessScript].
        if (element.optBoolean("pointerHit", false)) map["domPointerHit"] = MetadataValue.Bool(true)
        if (element.optBoolean("crossOriginFrame", false)) {
            map["domCrossOriginFrame"] = MetadataValue.Bool(true)
        }
        // A frame's identity and the reason its subtree is empty, if it is. All of
        // these are readable across origins — policy withholds the document, not the
        // element — and they are what separates "still loading, retry" from "another
        // origin, use coordinates" from "the page sandboxed it, fix the page".
        putText("domFrameOpaque", element.optString("frameOpaque"))
        putText("domFrameName", element.optString("frameName"))
        putText("domFrameUrl", element.optString("frameUrl"))
        putText("domFrameReadyState", element.optString("frameReadyState"))
        putText("domFrameSandbox", element.optString("frameSandbox"))
        putText("domFrameAllow", element.optString("frameAllow"))
        putText("domFrameLoading", element.optString("frameLoading"))
        // Why a frame that COULD have been read in its own context was not, and how one
        // that was got read. Both are about the MECHANISM, not the page: the first says
        // whether a retry (or a page navigation) would change anything, the second that
        // these nodes came from inside a wall.
        putText("domFrameProbe", element.optString("frameProbe"))
        putText("domFrameProbeDetail", element.optString("frameProbeDetail"))
        putText("domFramePierced", element.optString("framePierced"))
        val childFrames = element.optInt("frameChildCount", -1)
        if (childFrames >= 0) map["domFrameChildCount"] = MetadataValue.Integer(childFrames.toLong())
        // A rotated or skewed frame in the chain: the rect is the axis-aligned hull
        // of the real box, so a tap at its centre can miss. Stated, not smoothed.
        if (element.optBoolean("geometryApprox", false)) {
            map["domGeometryApprox"] = MetadataValue.Bool(true)
        }
        // The numbers behind the `scroll:` capability, kept as evidence: "one flick
        // left" and "twenty screens left" are the same flag and different situations.
        listOf(
            "domScrollLeft" to "scrollLeft",
            "domScrollTop" to "scrollTop",
            "domScrollWidth" to "scrollWidth",
            "domScrollHeight" to "scrollHeight",
            "domScrollClientWidth" to "scrollClientWidth",
            "domScrollClientHeight" to "scrollClientHeight",
        ).forEach { (metadataKey, elementKey) ->
            val value = element.optInt(elementKey, -1)
            if (value >= 0) map[metadataKey] = MetadataValue.Integer(value.toLong())
        }
        putText("domHasPopup", element.optString("hasPopup"))
        // Only where the pointer STARTS, and only as the weak signal it is: the
        // page said "clickable" and nothing declared a role.
        if (element.optBoolean("pointerOrigin", false)) {
            map["domCursor"] = MetadataValue.Text("pointer")
        }
        // Page-truth sibling positions, so `:nth-of-type(n)` / `:nth-child(n)` can be
        // MATCHED rather than refused. Counting the captured parent's children would
        // answer with the n-th VISIBLE sibling — the walk drops hidden elements — and
        // that is a silently-wrong tap, not an approximation.
        putInteger("domNthOfType", "nthOfType")
        putInteger("domNthChild", "nthChild")
        putText("domPlaceholder", element.optString("placeholder"))
        // Which accname rule produced the label, so a name inferred from a `<label>`
        // sitting beside the input (no `for`) is never read as a declared one.
        putText("domNameSource", element.optString("nameSource"))
        putText("domName", element.optString("formName"))
        putText("domDescribedBy", element.optString("describedBy"))
        if (element.optBoolean("invalid", false)) map["domInvalid"] = MetadataValue.Bool(true)
        putText("domMarginTop", element.optString("marginTop"))
        putText("domMarginRight", element.optString("marginRight"))
        putText("domMarginBottom", element.optString("marginBottom"))
        putText("domMarginLeft", element.optString("marginLeft"))
        listOf(
            "domStyleDisplay" to "styleDisplay",
            "domStyleVisibility" to "styleVisibility",
            "domStyleOpacity" to "styleOpacity",
            "domStylePosition" to "stylePosition",
            "domStyleZIndex" to "styleZIndex",
            "domStyleOverflowX" to "styleOverflowX",
            "domStyleOverflowY" to "styleOverflowY",
            "domStyleColor" to "styleColor",
            "domStyleBackgroundColor" to "styleBackgroundColor",
            "domStyleBackgroundImage" to "styleBackgroundImage",
            "domStyleFontSize" to "styleFontSize",
            "domStyleFontWeight" to "styleFontWeight",
            "domStyleFontFamily" to "styleFontFamily",
            "domStyleLineHeight" to "styleLineHeight",
            "domStyleTextAlign" to "styleTextAlign",
            "domStylePaddingTop" to "stylePaddingTop",
            "domStylePaddingRight" to "stylePaddingRight",
            "domStylePaddingBottom" to "stylePaddingBottom",
            "domStylePaddingLeft" to "stylePaddingLeft",
            "domStyleBorderTopWidth" to "styleBorderTopWidth",
            "domStyleBorderRightWidth" to "styleBorderRightWidth",
            "domStyleBorderBottomWidth" to "styleBorderBottomWidth",
            "domStyleBorderLeftWidth" to "styleBorderLeftWidth",
            "domStyleBorderRadius" to "styleBorderRadius",
            "domStyleTransform" to "styleTransform",
            "domStylePointerEvents" to "stylePointerEvents",
        ).forEach { (metadataKey, elementKey) ->
            putText(metadataKey, element.optString(elementKey))
        }
        map["domScaleX"] = MetadataValue.Real(fold.scaleX)
        map["domScaleY"] = MetadataValue.Real(fold.scaleY)
        return map
    }

    private data class CoordinateFold(
        val webViewFrame: Rect,
        val scaleX: Double,
        val scaleY: Double,
    ) {
        /**
         * The script reports VIEWPORT coordinates, so no scroll enters here — see the
         * note on `left`/`top` in dom-traversal.js. This used to add the page scroll
         * per element (during the walk) and subtract it once (read after the walk), so
         * a page that scrolled or reflowed mid-walk folded to rects offset by the
         * delta — silent, and measured on a real page at roughly 130px.
         */
        fun rectFor(element: JSONObject): Rect {
            val left = element.optDouble("left")
            val top = element.optDouble("top")
            return Rect(
                x = webViewFrame.x + left * scaleX,
                y = webViewFrame.y + top * scaleY,
                width = element.optDouble("width") * scaleX,
                height = element.optDouble("height") * scaleY,
            )
        }

        companion object {
            fun from(json: JSONObject, webViewFrame: Rect, density: Double): CoordinateFold {
                val viewportWidth = json.optDouble("viewportWidth", 0.0)
                val viewportHeight = json.optDouble("viewportHeight", 0.0)
                return CoordinateFold(
                    webViewFrame = webViewFrame,
                    scaleX = if (viewportWidth > 0.0) webViewFrame.width / viewportWidth else density,
                    scaleY = if (viewportHeight > 0.0) webViewFrame.height / viewportHeight else density,
                )
            }
        }
    }

    private fun JSONArray?.forEachObject(block: (JSONObject) -> Unit) {
        if (this == null) return
        for (i in 0 until length()) {
            optJSONObject(i)?.let(block)
        }
    }

    private fun String?.nullIfBlank(): String? = this?.takeIf { it.isNotBlank() }
}
