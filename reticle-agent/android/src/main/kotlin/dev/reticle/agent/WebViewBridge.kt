package dev.reticle.agent

import android.os.Handler
import android.os.Looper
import android.webkit.WebView
import dev.reticle.core.CheckedState
import dev.reticle.core.MetadataValue
import dev.reticle.core.Node
import dev.reticle.core.NodeKind
import dev.reticle.core.Rect
import dev.reticle.core.StyleChannel
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
                custom = parent.custom + extra,
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
    )

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
        val fold = CoordinateFold.from(json, pending.webViewFrame, density)
        val ref = visit(root, pending.parentRef, fold, nodes, makeRef)
        return Walk(
            refs = ref?.let { listOf(it) } ?: emptyList(),
            capped = json.optBoolean("capped", false),
            captured = json.optLong("captured"),
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
        if (element.optBoolean("crossOriginFrame", false)) {
            map["domCrossOriginFrame"] = MetadataValue.Bool(true)
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
        val scrollX: Double,
        val scrollY: Double,
    ) {
        fun rectFor(element: JSONObject): Rect {
            val left = element.optDouble("left") - scrollX
            val top = element.optDouble("top") - scrollY
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
                    scrollX = json.optDouble("scrollX", 0.0),
                    scrollY = json.optDouble("scrollY", 0.0),
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
