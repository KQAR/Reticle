package dev.reticle.agent

import android.content.Context
import android.content.res.Configuration
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.DisplayMetrics
import android.view.View
import android.view.SurfaceView
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
import dev.reticle.core.StyleChannel
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
        // draft.nodes is the same mutable map the snapshot already holds, so the
        // WebView DOM nodes append straight into it — no full-map copy + copy().
        WebViewBridge.captureInto(
            pending = draft.webViews,
            density = draft.snapshot.screen.density,
            handler = handler,
            nodes = draft.nodes,
        ) { makeRef() }
        return draft.snapshot
    }

    /**
     * Resolve a snapshot [ref] back to its View, using the exact same tree walk
     * and ref numbering that [capture] uses — so a ref taken from a snapshot maps
     * to the same View here. Non-View refs (Compose/probe/WebView-DOM nodes) are
     * absent, since only Views can be mutated. Must be called on the main thread
     * (or off it — it hops on internally); it skips the async WebView DOM pass.
     */
    fun viewByRef(ref: String): View? {
        val index = HashMap<String, View>()
        runOnMainSync { captureLocked(viewIndex = index) }
        return index[ref]
    }

    private data class CaptureDraft(
        val snapshot: Snapshot,
        val webViews: List<WebViewBridge.Pending>,
        /** The same mutable map [snapshot] holds; WebView DOM nodes append here. */
        val nodes: MutableMap<String, Node>,
    )

    private fun captureLocked(viewIndex: MutableMap<String, View>? = null): CaptureDraft {
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
                viewIndex = viewIndex,
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
            nodes = nodes,
        )
    }

    private fun captureView(
        view: View,
        parentRef: String,
        kindOverride: NodeKind? = null,
        nodes: MutableMap<String, Node>,
        webViews: MutableList<WebViewBridge.Pending>,
        viewIndex: MutableMap<String, View>? = null,
    ): String {
        val ref = makeRef()
        viewIndex?.put(ref, view)
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
                    childRefs.add(
                        captureView(
                            child,
                            parentRef = ref,
                            nodes = nodes,
                            webViews = webViews,
                            viewIndex = viewIndex,
                        )
                    )
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
        val testId = ReticleReflect.testTag(view) ?: ReticleReflect.nativeId(view) ?: resourceId
        val text = (view as? TextView)?.text?.toString()
        val isInteractive = view.isClickable || view.isLongClickable || view.isFocusable

        val style = scalarProperties(view)
        // Discover sub-regions within this single View (span links, virtual
        // a11y nodes, touch-delegate), plus a char grid for substring targeting.
        val region = RegionProbe.probe(view)
        // A Lottie bakes its whole UI into one opaque canvas; recover its named
        // text layers as sub-regions so they stay targetable.
        val lottieRegions = LottieBridge.regionsFor(view, frame)

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
            // Focus, separately from clickability: a compound input widget's outer
            // container is clickable but cannot take text, and tapping it leaves the
            // nested EditText unfocused. `act type` reads these back to check that
            // the field it aimed at is the field that got focus.
            // focusableInTouchMode, NOT isFocusable: since API 26 FOCUSABLE_AUTO
            // makes any clickable container report isFocusable=true while a tap
            // moves no focus into it — the false positive this field exists to avoid.
            isFocusable = view.isFocusableInTouchMode,
            isFocused = view.isFocused,
            custom = style.values +
                screenshotStatus(view, isWindow = kindOverride == NodeKind.window) +
                foreignWebKernel(view),
            styleChannels = style.channels,
            styleGaps = style.gaps,
            children = childRefs,
            regions = region.regions + lottieRegions,
            suspectedMultiRegion = region.suspectedMultiRegion,
            charGrid = region.charGrid,
            scroll = scrollInfo(view),
        )
        return ref
    }

    /**
     * Label the two ways a screenshot lies about this node, so an absence in the
     * picture is never inferred from a blank rect. Both were measured on an emulator
     * with `scenario.screenshotDegrade`:
     *
     * - a `SurfaceView` draws into its own surface, composited by SurfaceFlinger, so
     *   the in-process Canvas walk leaves a transparent hole (rgba 0,0,0,0) exactly
     *   where the magenta surface is, while `adb exec-out screencap` shows it;
     * - `FLAG_SECURE` is the mirror image — the in-process capture is unaffected
     *   while the device-level capture comes back fully blanked (rgba 0,0,0,255).
     */
    private fun screenshotStatus(view: View, isWindow: Boolean): Map<String, MetadataValue> {
        val out = LinkedHashMap<String, MetadataValue>()
        if (view is SurfaceView) {
            out["pixelStatus"] = MetadataValue.Text("unavailable")
        }
        if (isWindow && secureWindow(view)) {
            out["screencapStatus"] = MetadataValue.Text("blank")
        }
        return out
    }

    /**
     * A **suspected third-party WebView kernel** — X5/TBS
     * (`com.tencent.smtt.sdk.WebView`), UC (`com.uc.webview.export.WebView`), and
     * their kin. `WebViewBridge` is typed on `android.webkit.WebView`, so none of
     * them can be bridged and the view is simply an opaque rect: no DOM at any
     * level, ever. Reticle deliberately does NOT add a reflective adapter for them
     * (it could not be verified without a real kernel sample), so the honest move is
     * to make the boundary say its own name instead of looking like an empty page.
     *
     * The test is the shape, not a vendor list: a class that calls itself a WebView
     * yet is not the platform one. An app's own subclass of the real `WebView` never
     * reaches here (it IS a `WebView`), and a container that merely wraps one is
     * excluded by the descendant check — a wrapper's DOM is available through the
     * real view inside it. "Suspected" is the honest word, so the class name rides
     * along as evidence.
     */
    private fun foreignWebKernel(view: View): Map<String, MetadataValue> {
        if (view is WebView) return emptyMap()
        val className = view.javaClass.name
        if (!className.contains("WebView")) return emptyMap()
        if (containsSystemWebView(view)) return emptyMap()
        return mapOf(
            "domStatus" to MetadataValue.Text("unsupportedKernel"),
            "domKernel" to MetadataValue.Text(className),
        )
    }

    /** Does this subtree hold a real `android.webkit.WebView`? Then it is a wrapper. */
    private fun containsSystemWebView(view: View): Boolean {
        if (view is WebView) return true
        if (view !is ViewGroup) return false
        for (i in 0 until view.childCount) {
            val child = view.getChildAt(i) ?: continue
            if (containsSystemWebView(child)) return true
        }
        return false
    }

    /** `FLAG_SECURE` on this window root's layout params, when it has any. */
    private fun secureWindow(root: View): Boolean {
        val params = root.layoutParams as? WindowManager.LayoutParams ?: return false
        return (params.flags and WindowManager.LayoutParams.FLAG_SECURE) != 0
    }

    /**
     * A container's current scroll capability, or null when it has none.
     *
     * `canScrollVertically/Horizontally` is the one signal every scrolling
     * container implements — `RecyclerView`, `ScrollView`, `NestedScrollView`,
     * `ViewPager2`, `AbsListView` — so this needs no per-class allowlist. It
     * matters because a recycling container keeps only its visible window bound:
     * a far-down row has NO node at all, and without this flag that is
     * indistinguishable from an element the app doesn't have.
     *
     * Restricted to `ViewGroup`s on purpose: a `TextView` whose text overflows
     * also answers `canScrollVertically(1) == true` (it scrolls its own text), and
     * reporting every truncated label as scrollable content would bury the one
     * container an agent actually needs to move.
     */
    /**
     * Whether this app's topmost window still has input focus. `hasWindowFocus`
     * is the framework's own answer and covers exactly the case the tree cannot:
     * another process's window (a permission prompt, a biometric sheet) took
     * focus, so it exists on screen but in none of our windows.
     */
    private fun topWindowFocused(): Boolean? {
        val roots = ReticleWindows.rootViews()
        if (roots.isEmpty()) return null
        return try {
            roots.any { it.hasWindowFocus() }
        } catch (_: Throwable) {
            null
        }
    }

    private fun scrollInfo(view: View): dev.reticle.core.ScrollInfo? {
        if (view !is android.view.ViewGroup) return null
        return try {
            val info = dev.reticle.core.ScrollInfo(
                canScrollUp = view.canScrollVertically(-1),
                canScrollDown = view.canScrollVertically(1),
                canScrollLeft = view.canScrollHorizontally(-1),
                canScrollRight = view.canScrollHorizontally(1),
            )
            if (info.isScrollable) info else null
        } catch (_: Throwable) {
            null
        }
    }

    private fun roleFor(view: View): String = when (view) {
        is android.widget.Button -> "button"
        is android.widget.EditText -> "textField"
        is android.widget.ImageView -> "image"
        is TextView -> "text"
        is android.widget.ScrollView -> "scrollView"
        else -> if (view is ViewGroup) "container" else "view"
    }

    /**
     * A view's scalar properties, split three ways: the values, which channel each
     * STYLE value was read through, and the style properties this view is known to
     * have but which no channel can read.
     *
     * The split is the point. A consumer holding these up against a design has to
     * tell "the app set no font weight" from "Reticle cannot see the font weight",
     * and a bare map of values makes those two look identical. Non-style entries
     * (`tag`, app-authored metadata) get no channel, so `styleChannels` doubles as
     * the answer to "which of these keys are style".
     */
    private data class ViewStyle(
        val values: Map<String, MetadataValue>,
        val channels: Map<String, StyleChannel>,
        val gaps: Map<String, String>,
    )

    private fun scalarProperties(view: View): ViewStyle {
        val map = LinkedHashMap<String, MetadataValue>()
        val channels = LinkedHashMap<String, StyleChannel>()
        val gaps = LinkedHashMap<String, String>()

        fun put(name: String, value: MetadataValue, channel: StyleChannel) {
            map[name] = value
            channels[name] = channel
        }

        put("alpha", MetadataValue.Real(view.alpha.toDouble()), StyleChannel.viewField)
        put("elevation", MetadataValue.Real(view.elevation.toDouble()), StyleChannel.viewField)
        put(
            "visibility",
            MetadataValue.Text(
                when (view.visibility) {
                    View.VISIBLE -> "visible"
                    View.INVISIBLE -> "invisible"
                    else -> "gone"
                }
            ),
            StyleChannel.viewField,
        )
        // Padding, not the gap between two frames: a frame-to-frame measurement
        // cannot say whether the space belongs to this view, its neighbour or their
        // parent, which is exactly what a spacing spec states.
        put("paddingLeft", MetadataValue.Real(view.paddingLeft.toDouble()), StyleChannel.viewField)
        put("paddingTop", MetadataValue.Real(view.paddingTop.toDouble()), StyleChannel.viewField)
        put("paddingRight", MetadataValue.Real(view.paddingRight.toDouble()), StyleChannel.viewField)
        put("paddingBottom", MetadataValue.Real(view.paddingBottom.toDouble()), StyleChannel.viewField)

        view.tag?.let { map["tag"] = MetadataValue.Text(it.toString()) }

        ReticleReflect.backgroundColorHex(view)?.let {
            put("backgroundColor", MetadataValue.Text(it), StyleChannel.viewField)
        }
        // Shape lives on the background Drawable, which no View getter exposes.
        val shape = ReticleReflect.shapeMetrics(view)
        shape.cornerRadiusPx?.let { put("cornerRadius", MetadataValue.Real(it.toDouble()), StyleChannel.drawableReflect) }
        shape.cornerRadiusGap?.let { gaps["cornerRadius"] = it }
        shape.strokeWidthPx?.let { put("borderWidth", MetadataValue.Real(it.toDouble()), StyleChannel.drawableReflect) }
        shape.strokeColorHex?.let { put("borderColor", MetadataValue.Text(it), StyleChannel.drawableReflect) }
        if (!map.containsKey("backgroundColor")) {
            shape.fillColorHex?.let { put("backgroundColor", MetadataValue.Text(it), StyleChannel.drawableReflect) }
        }

        if (view is TextView) {
            put("textColor", MetadataValue.Text(ReticleReflect.colorHex(view.currentTextColor)), StyleChannel.viewField)
            put("textSize", MetadataValue.Real(view.textSize.toDouble()), StyleChannel.viewField)
            put("lineHeight", MetadataValue.Real(view.lineHeight.toDouble()), StyleChannel.viewField)
            // Only a REAL limit. An unset maxLines reads back as Integer.MAX_VALUE,
            // which rendered as `maxLines 2147483647` — a number that looks like a
            // finding and means "no limit".
            view.maxLines.takeIf { it in 1 until Int.MAX_VALUE }?.let {
                put("maxLines", MetadataValue.Integer(it.toLong()), StyleChannel.viewField)
            }
            put("textAlign", MetadataValue.Text(textAlign(view)), StyleChannel.viewField)
            // Android states letter spacing in ems; every other length here is a
            // device length, so convert once at the source rather than leaving two
            // incompatible units under one name.
            runCatching { view.letterSpacing * view.textSize }.getOrNull()?.let {
                put("letterSpacing", MetadataValue.Real(it.toDouble()), StyleChannel.viewField)
            }
            view.typeface?.let { typeface ->
                val weight = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    typeface.weight
                } else {
                    if (typeface.isBold) 700 else 400
                }
                put("fontWeight", MetadataValue.Integer(weight.toLong()), StyleChannel.viewField)
                put(
                    "fontStyle",
                    MetadataValue.Text(if (typeface.isItalic) "italic" else "normal"),
                    StyleChannel.viewField,
                )
                // A Typeface names no family: the platform exposes weight and slant
                // and nothing else, so the one text property a design always states
                // by name is structurally unreadable here. Compose text DOES carry
                // it (see ComposeTextStyle), which is why this is a gap on this
                // channel rather than a boundary for the whole platform.
                gaps["fontFamily"] = "android-typeface-exposes-no-family"
            }
            // The tint clickable spans render with (android:textColorLink). A
            // run drawn in this color is very likely a tappable link.
            runCatching { view.linkTextColors?.defaultColor }.getOrNull()?.let {
                put("linkTextColor", MetadataValue.Text(ReticleReflect.colorHex(it)), StyleChannel.viewField)
            }
        }
        // Merge app-attached metadata addressed by testId. Deliberately untagged:
        // the app can publish anything here, and Reticle cannot know which of its
        // keys are style without being told.
        ReticleReflect.testTag(view)?.let { tag ->
            ReticleRuntime.shared.metadata(tag).forEach { (k, v) -> map[k] = v }
        }
        return ViewStyle(map, channels, gaps)
    }

    /** Horizontal gravity as a design-facing keyword. */
    private fun textAlign(view: TextView): String {
        val horizontal = view.gravity and android.view.Gravity.HORIZONTAL_GRAVITY_MASK
        val relative = view.gravity and android.view.Gravity.RELATIVE_HORIZONTAL_GRAVITY_MASK
        return when {
            relative and android.view.Gravity.END == android.view.Gravity.END -> "end"
            relative and android.view.Gravity.START == android.view.Gravity.START -> "start"
            horizontal == android.view.Gravity.CENTER_HORIZONTAL -> "center"
            horizontal == android.view.Gravity.RIGHT -> "right"
            else -> "left"
        }
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
            // Without this a text size cannot be split into "the app asked for the
            // wrong size" (compare in dp) and "the user enlarged text" (compare in
            // sp). Assuming 1.0 silently merges the two.
            fontScale = context.resources.configuration.fontScale.toDouble(),
            interfaceStyle = if (night) "dark" else "light",
            // captureLocked already runs on the main thread, which the probe needs.
            keyboard = KeyboardProbe.probe(context),
            windowFocused = topWindowFocused(),
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
}
