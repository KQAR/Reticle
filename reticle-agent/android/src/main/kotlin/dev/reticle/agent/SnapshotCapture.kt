package dev.reticle.agent

import android.content.Context
import android.content.res.Configuration
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.DisplayMetrics
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.webkit.WebView
import android.widget.TextView
import dev.reticle.core.MetadataValue
import dev.reticle.core.Node
import dev.reticle.core.NodeKind
import dev.reticle.core.Rect
import dev.reticle.core.ScreenInfo
import dev.reticle.core.Size
import dev.reticle.core.Snapshot
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Captures a view-tree snapshot from inside the app process: it enumerates the
 * attached window roots, walks the View hierarchy, reflects scalar properties,
 * and emits a flat ref -> Node map rooted at the application.
 *
 * It walks WindowManagerGlobal.getRootViews() -> ViewGroup -> View, the full set
 * of attached decor/window roots (activities, dialogs, popups, toasts).
 */
class SnapshotCapture(private val context: Context) {

    private var nextRef = 0
    private val handler = Handler(Looper.getMainLooper())

    fun capture(): Snapshot {
        // The View tree must be read on the main thread. WebView DOM reads are
        // async UI-thread callbacks, so they are appended after the view walk
        // while this server thread waits off the main looper.
        val draft = runOnMainSync { captureLocked() }
        val nodes = LinkedHashMap(draft.snapshot.nodes)
        WebViewBridge.captureInto(
            pending = draft.webViews,
            density = draft.snapshot.screen.density,
            handler = handler,
            nodes = nodes,
        ) { makeRef() }
        return draft.snapshot.copy(nodes = nodes)
    }

    private data class CaptureDraft(
        val snapshot: Snapshot,
        val webViews: List<WebViewBridge.Pending>,
    )

    private fun captureLocked(): CaptureDraft {
        nextRef = 0
        val nodes = LinkedHashMap<String, Node>()
        val webViews = ArrayList<WebViewBridge.Pending>()

        val appRef = makeRef()
        val rootViews = ReticleWindows.rootViews()
        val windowRefs = ArrayList<String>()

        for (root in rootViews) {
            val windowRef = captureView(
                view = root,
                parentRef = appRef,
                kindOverride = NodeKind.window,
                nodes = nodes,
                webViews = webViews,
            )
            windowRefs.add(windowRef)
        }

        // Attach app-authored probe nodes addressed by testId: registered probes
        // appear as synthetic children of the application.
        val probeRefs = ArrayList<String>()
        for ((testId, metadata) in ReticleProbeRegistry.all()) {
            val ref = makeRef()
            nodes[ref] = Node(
                ref = ref,
                parentRef = appRef,
                kind = NodeKind.probe,
                typeName = "ReticleProbe",
                role = "probe",
                testId = testId,
                custom = metadata,
            )
            probeRefs.add(ref)
        }

        nodes[appRef] = Node(
            ref = appRef,
            parentRef = null,
            kind = NodeKind.application,
            typeName = "android.app.Application",
            role = "application",
            children = windowRefs + probeRefs,
        )

        return CaptureDraft(
            snapshot = Snapshot(
                capturedAtMillis = System.currentTimeMillis(),
                screen = screenInfo(),
                rootRef = appRef,
                nodes = nodes,
            ),
            webViews = webViews,
        )
    }

    private fun captureView(
        view: View,
        parentRef: String,
        kindOverride: NodeKind? = null,
        nodes: MutableMap<String, Node>,
        webViews: MutableList<WebViewBridge.Pending>,
    ): String {
        val ref = makeRef()
        val location = IntArray(2)
        view.getLocationOnScreen(location)
        val frame = Rect(
            x = location[0].toDouble(),
            y = location[1].toDouble(),
            width = view.width.toDouble(),
            height = view.height.toDouble(),
        )

        val childRefs = ArrayList<String>()
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                view.getChildAt(i)?.let { child ->
                    childRefs.add(captureView(child, parentRef = ref, nodes = nodes, webViews = webViews))
                }
            }
        }

        // Merge any Compose semantics exposed by this view (AndroidComposeView).
        val composeChildren = ComposeSemanticsBridge.captureInto(view, parentRef = ref, nodes = nodes) {
            makeRef()
        }
        childRefs.addAll(composeChildren)

        if (view is WebView) {
            webViews.add(WebViewBridge.Pending(webView = view, parentRef = ref, webViewFrame = frame))
        }

        val resourceId = ReticleReflect.resourceEntryName(view)
        val testId = ReticleReflect.testTag(view) ?: resourceId
        val text = (view as? TextView)?.text?.toString()
        val isInteractive = view.isClickable || view.isLongClickable || view.isFocusable

        // Discover sub-regions within this single View (span links, virtual
        // a11y nodes, touch-delegate), plus a char grid for substring targeting.
        val region = RegionProbe.probe(view)

        nodes[ref] = Node(
            ref = ref,
            parentRef = parentRef,
            kind = kindOverride ?: NodeKind.view,
            typeName = view.javaClass.name,
            role = roleFor(view),
            resourceId = resourceId,
            contentDescription = view.contentDescription?.toString(),
            text = text,
            testId = testId,
            frame = frame,
            isVisible = view.visibility == View.VISIBLE && view.width > 0 && view.height > 0,
            isEnabled = view.isEnabled,
            isInteractive = isInteractive,
            custom = scalarProperties(view),
            children = childRefs,
            regions = region.regions,
            suspectedMultiRegion = region.suspectedMultiRegion,
            charGrid = region.charGrid,
        )
        return ref
    }

    private fun roleFor(view: View): String = when (view) {
        is android.widget.Button -> "button"
        is android.widget.EditText -> "textField"
        is android.widget.ImageView -> "image"
        is TextView -> "text"
        is android.widget.ScrollView -> "scrollView"
        else -> if (view is ViewGroup) "container" else "view"
    }

    private fun scalarProperties(view: View): Map<String, MetadataValue> {
        val map = LinkedHashMap<String, MetadataValue>()
        map["alpha"] = MetadataValue.Real(view.alpha.toDouble())
        map["elevation"] = MetadataValue.Real(view.elevation.toDouble())
        map["visibility"] = MetadataValue.Text(
            when (view.visibility) {
                View.VISIBLE -> "visible"
                View.INVISIBLE -> "invisible"
                else -> "gone"
            }
        )
        view.tag?.let { map["tag"] = MetadataValue.Text(it.toString()) }
        ReticleReflect.backgroundColorHex(view)?.let { map["backgroundColor"] = MetadataValue.Text(it) }
        if (view is TextView) {
            map["textColor"] = MetadataValue.Text(ReticleReflect.colorHex(view.currentTextColor))
            map["textSize"] = MetadataValue.Real(view.textSize.toDouble())
            // The tint clickable spans render with (android:textColorLink). A
            // run drawn in this color is very likely a tappable link.
            runCatching { view.linkTextColors?.defaultColor }.getOrNull()?.let {
                map["linkTextColor"] = MetadataValue.Text(ReticleReflect.colorHex(it))
            }
        }
        // Merge app-attached metadata addressed by testId.
        ReticleReflect.testTag(view)?.let { tag ->
            ReticleRuntime.shared.metadata(tag).forEach { (k, v) -> map[k] = v }
        }
        return map
    }

    private fun screenInfo(): ScreenInfo {
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        wm.defaultDisplay.getRealMetrics(metrics)
        val night = (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES
        return ScreenInfo(
            size = Size(metrics.widthPixels.toDouble(), metrics.heightPixels.toDouble()),
            density = metrics.density.toDouble(),
            interfaceStyle = if (night) "dark" else "light",
        )
    }

    private fun makeRef(): String = "r${nextRef++}"

    private fun <T> runOnMainSync(block: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            return block()
        }
        var result: T? = null
        var error: Throwable? = null
        val latch = CountDownLatch(1)
        handler.post {
            try {
                result = block()
            } catch (t: Throwable) {
                error = t
            } finally {
                latch.countDown()
            }
        }
        if (!latch.await(5, TimeUnit.SECONDS)) {
            throw IllegalStateException("Timed out capturing view tree on main thread")
        }
        error?.let { throw it }
        @Suppress("UNCHECKED_CAST")
        return result as T
    }

    @Suppress("unused")
    private fun sdkInt(): Int = Build.VERSION.SDK_INT
}
