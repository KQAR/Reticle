package dev.reticle.agent

import android.os.Handler
import android.webkit.WebView
import dev.reticle.core.WebViewDomScript
import org.json.JSONObject
import java.lang.reflect.Proxy
import java.util.Collections
import java.util.WeakHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Per-frame DOM reads on Android — including frames whose document the page itself may
 * not read.
 *
 * `WebView.evaluateJavascript` runs in the MAIN frame, so a cross-origin (or
 * `sandbox`-sealed) frame was a wall: the frame element with no children, and
 * coordinates as the only way in. The iOS twin (`WebFrameProbe`) crosses that wall with
 * WebKit's frame-scoped evaluation. Android has no such call, but androidx.webkit
 * provides the two halves that add up to the same thing:
 *
 *  - `WebViewCompat.addDocumentStartJavaScript` injects a script into **every frame**
 *    that matches an origin rule, at document start — the injection a foreign frame
 *    would otherwise never accept.
 *  - `WebViewCompat.addWebMessageListener` puts a JS object in those same frames that
 *    posts back to the app, so a frame can answer.
 *
 * So the read is push-based rather than pull-based: the main frame posts a request to a
 * frame (`postMessage` is allowed across origins, and so is walking `window.frames[i]`
 * to reach a nested one), the probe inside that frame runs the SAME traversal script
 * with the fold its parent measured, and posts the result back. One capture waits for
 * the replies it asked for.
 *
 * Three things are deliberate:
 *
 *  - **androidx.webkit is `compileOnly` and reached by reflection.** An app that does
 *    not ship it links the agent exactly as before, and the `app inject` payload dex —
 *    which lands in an arbitrary app — carries no support library that could collide
 *    with the host's own copy. Absence is reported (`iframe:probe-unavailable`), never
 *    guessed around.
 *  - **The origin rule is `*`.** Narrower rules would mean guessing which third-party
 *    origin a widget will use; a debug-time observer that reads the frames it is asked
 *    about is the honest scope, and the injected code only ever reads.
 *  - **A document that loaded before the injection was registered is not covered.**
 *    Same limit as iOS, same marker (`iframe:probe-needs-reload`), and the same
 *    refusal to fix it by reloading the app's page: that would be the observer changing
 *    the thing observed.
 */
object WebFrameBridge {

    /** Marker values for [WebViewBridge.metadataFor]'s `domFrameProbe`. */
    const val PROBE_UNAVAILABLE = "unavailable"
    const val PROBE_NEEDS_RELOAD = "needs-reload"
    const val PROBE_BUDGET = "budget"
    const val PROBE_DEPTH_BUDGET = "depth-budget"
    const val PROBE_NO_HANDLE = "no-handle"
    const val PROBE_FAILED = "failed"

    /** At most this many frames per capture, at most this deep — the iOS budgets. */
    const val FRAME_BUDGET = 6
    const val DEPTH_BUDGET = 4

    /** One round of replies. A frame that cannot script can never answer, so the wait
     *  is bounded by time rather than by the number of frames asked. */
    private const val ROUND_TIMEOUT_MS = 600L

    private const val JS_OBJECT = "reticleFrames"
    private val ORIGIN_RULES: Set<String> = Collections.singleton("*")

    /** Replies from one web view's frames, keyed by the index path that was asked. */
    private class Replies {
        val payloads = HashMap<String, String>()
        var latch: CountDownLatch? = null
        var expected: MutableSet<String> = HashSet()
    }

    private val replies = WeakHashMap<WebView, Replies>()
    private val installed = WeakHashMap<WebView, Boolean>()

    /**
     * True when this build can read a frame in its own context at all: androidx.webkit
     * is on the classpath AND the WebView implementation on this device supports both
     * features. Both halves are runtime facts — the support library is compileOnly, and
     * a feature depends on the (updatable) WebView provider.
     */
    fun isAvailable(): Boolean = unavailableReason() == null

    /**
     * null when a frame CAN be read in its own context here; otherwise which half is
     * missing — `"no-library"` (androidx.webkit is not in this app),
     * `"no-feature:<NAME>"` (this device's WebView provider does not implement it), or
     * `"reflection:<message>"` (the library is present and did not answer as expected,
     * which is a Reticle bug rather than an app or device fact).
     *
     * Three separate answers on purpose: they were one boolean first, and a boolean
     * cannot tell an app that needs a dependency from a device that needs a newer
     * WebView from a call that is simply wrong.
     */
    fun unavailableReason(): String? {
        val featureClass = try {
            Class.forName("androidx.webkit.WebViewFeature")
        } catch (_: Throwable) {
            return "no-library"
        }
        for (name in listOf("DOCUMENT_START_SCRIPT", "WEB_MESSAGE_LISTENER")) {
            val supported = try {
                val constant = featureClass.getField(name).get(null) as String
                featureClass.getMethod("isFeatureSupported", String::class.java)
                    .invoke(null, constant) as Boolean
            } catch (t: Throwable) {
                return "reflection:${t.javaClass.simpleName}:${t.message?.take(80)}"
            }
            if (!supported) return "no-feature:$name"
        }
        return null
    }

    /**
     * Register the probe and the reply channel on this web view. Idempotent, and MUST
     * run on the UI thread. Returns false when the platform cannot do it.
     */
    fun install(webView: WebView): Boolean {
        if (!isAvailable()) return false
        if (installed[webView] == true) return true
        val ok = runCatching {
            val compat = Class.forName("androidx.webkit.WebViewCompat")
            val listenerClass = Class.forName("androidx.webkit.WebViewCompat\$WebMessageListener")
            val listener = Proxy.newProxyInstance(
                listenerClass.classLoader,
                arrayOf(listenerClass),
            ) { _, method, args ->
                if (method.name == "onPostMessage") onPostMessage(webView, args)
                null
            }
            compat.getMethod(
                "addWebMessageListener",
                WebView::class.java,
                String::class.java,
                Set::class.java,
                listenerClass,
            ).invoke(null, webView, JS_OBJECT, ORIGIN_RULES, listener)
            compat.getMethod(
                "addDocumentStartJavaScript",
                WebView::class.java,
                String::class.java,
                Set::class.java,
            ).invoke(null, webView, PROBE_SCRIPT, ORIGIN_RULES)
            true
        }.getOrDefault(false)
        if (ok) installed[webView] = true
        return ok
    }

    /**
     * A frame's reply: `{ id, payload }`, where the payload is the traversal's own JSON
     * for that frame. Delivered on the UI thread by the WebView.
     */
    private fun onPostMessage(webView: WebView, args: Array<out Any?>?) {
        val message = args?.getOrNull(1) ?: return
        val data = runCatching {
            message.javaClass.getMethod("getData").invoke(message) as? String
        }.getOrNull() ?: return
        val json = runCatching { JSONObject(data) }.getOrNull() ?: return
        val id = json.optString("id").takeIf { it.isNotBlank() } ?: return
        val payload = json.optString("payload").takeIf { it.isNotBlank() && it != "null" }
        val slot = synchronized(replies) { replies[webView] } ?: return
        synchronized(slot) {
            if (payload != null) slot.payloads[id] = payload
            if (slot.expected.remove(id) && slot.expected.isEmpty()) slot.latch?.countDown()
        }
    }

    /** What one frame needs to be read: where it is, and how its content folds out. */
    data class Request(val path: String, val ctx: JSONObject, val prefix: String)

    /**
     * Ask each requested frame to walk itself, and wait for the replies this round.
     * Returns the raw traversal JSON per frame path; a path that is absent did not
     * answer (no probe inside it, or it cannot script at all).
     *
     * MUST be called off the UI thread.
     */
    fun read(webView: WebView, requests: List<Request>, handler: Handler): Map<String, String> {
        if (requests.isEmpty()) return emptyMap()
        val slot = synchronized(replies) { replies.getOrPut(webView) { Replies() } }
        val latch = CountDownLatch(1)
        synchronized(slot) {
            slot.payloads.clear()
            slot.expected = requests.mapTo(HashSet()) { it.path }
            slot.latch = latch
        }
        val script = requestScript(requests)
        val posted = handler.post {
            runCatching {
                if (install(webView)) webView.evaluateJavascript(script) {}
            }
        }
        if (!posted) return emptyMap()
        latch.await(ROUND_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        return synchronized(slot) {
            slot.latch = null
            HashMap(slot.payloads)
        }
    }

    /**
     * The main-frame script that hands each frame its request.
     *
     * It walks `window.frames[i]` down the index path to reach a NESTED frame directly:
     * indexed access to a foreign window and `postMessage` to it are both allowed across
     * origins, so no forwarding chain (and no id handshake) is needed — the request
     * carries the id and the frame echoes it back.
     */
    private fun requestScript(requests: List<Request>): String {
        val payload = requests.joinToString(",") { request ->
            JSONObject()
                .put("id", request.path)
                .put("ctx", request.ctx)
                .put("prefix", request.prefix)
                .toString()
        }
        return """
            (function() {
              var requests = [$payload];
              for (var r = 0; r < requests.length; r++) {
                var request = requests[r];
                var target = window;
                var parts = request.id.split("/");
                var reached = true;
                for (var p = 0; p < parts.length; p++) {
                  try {
                    target = target.frames[parseInt(parts[p], 10)];
                  } catch (e) {
                    target = null;
                  }
                  if (!target) { reached = false; break; }
                }
                if (!reached) continue;
                try { target.postMessage({ __reticleFrame: request }, "*"); } catch (e) {}
              }
              return requests.length;
            })();
        """.trimIndent()
    }

    /**
     * The probe, injected into every frame at document start.
     *
     * The traversal script is embedded as the returned EXPRESSION of `walk()`: the
     * shared file is an IIFE, so `return <that IIFE>;` runs it and hands back its JSON
     * without `eval` (which a page's CSP may forbid) and without re-parsing the script
     * to unwrap it. `reticleFrameCtx` / `reticleFramePrefix` are closure variables here,
     * and the traversal reads them through `typeof` — which resolves lexically, so the
     * fold arrives without a single global being written.
     */
    private val PROBE_SCRIPT: String = """
        (function() {
          if (window.__reticleFrameProbe) return;
          window.__reticleFrameProbe = true;
          var reticleFrameCtx = null;
          var reticleFramePrefix = "";
          function walk() {
            return ${WebViewDomScript.SCRIPT}
          }
          window.addEventListener("message", function(event) {
            var request = event.data && event.data.__reticleFrame;
            if (!request || typeof request.id !== "string") return;
            reticleFrameCtx = request.ctx || null;
            reticleFramePrefix = typeof request.prefix === "string" ? request.prefix : "";
            var payload = null;
            try { payload = walk(); } catch (e) { payload = null; }
            try {
              $JS_OBJECT.postMessage(JSON.stringify({ id: request.id, payload: payload }));
            } catch (e) {}
          });
        })();
    """.trimIndent()
}
