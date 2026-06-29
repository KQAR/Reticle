package dev.reticle.agent

import android.os.Handler
import android.os.Looper
import android.webkit.WebView
import dev.reticle.core.MetadataValue
import dev.reticle.core.Node
import dev.reticle.core.NodeKind
import dev.reticle.core.Rect
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
            val refs = captureOne(capture, density, handler, nodes, makeRef)
            if (refs.isEmpty()) continue
            val parent = nodes[capture.parentRef] ?: continue
            nodes[capture.parentRef] = parent.copy(children = parent.children + refs)
        }
    }

    private fun captureOne(
        pending: Pending,
        density: Double,
        handler: Handler,
        nodes: MutableMap<String, Node>,
        makeRef: () -> String,
    ): List<String> {
        val encoded = evaluateDomScript(pending.webView, handler) ?: return emptyList()
        val payload = decodeJavascriptString(encoded) ?: return emptyList()
        val json = runCatching { JSONObject(payload) }.getOrNull() ?: return emptyList()
        val root = json.optJSONObject("root") ?: return emptyList()
        val fold = CoordinateFold.from(json, pending.webViewFrame, density)
        val ref = visit(root, pending.parentRef, fold, nodes, makeRef)
        return ref?.let { listOf(it) } ?: emptyList()
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
        val frame = fold.rectFor(element)

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
            isVisible = frame.width > 0.0 && frame.height > 0.0,
            isEnabled = !disabled,
            isInteractive = !disabled && element.optBoolean("interactive", false),
            custom = metadataFor(element, selector, fold),
            children = childRefs,
        )
        return ref
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
        putText("domTag", element.optString("tag"))
        putText("domId", element.optString("id"))
        putText("domClass", element.optString("className"))
        putText("domCssSelector", selector)
        putText("domHref", element.optString("href"))
        putText("domInputType", element.optString("inputType"))
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
