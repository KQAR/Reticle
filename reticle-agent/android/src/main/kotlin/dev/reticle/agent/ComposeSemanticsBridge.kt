package dev.reticle.agent

import android.view.View
import dev.reticle.core.MetadataValue
import dev.reticle.core.Node
import dev.reticle.core.NodeKind
import dev.reticle.core.Rect

/**
 * Compose semantics bridge. The boundary rule: a composable is a valid
 * movement/input target only when it is exposed through the platform
 * accessibility/semantics surface (not from private Compose internals).
 *
 * There is no classic View per composable. The honest, stable surface is the
 * SemanticsNode tree (the same tree that backs platform accessibility and
 * Modifier.testTag). We read it reflectively so the agent has no hard Compose
 * dependency and links cleanly into pure-View apps. These merged nodes are
 * captured into the snapshot, from which Reticle's own SemanticTree is derived.
 *
 * If the view is not an AndroidComposeView, or the Compose runtime shape
 * changes, we emit nothing rather than inventing selectors from private
 * internals.
 */
object ComposeSemanticsBridge {

    // Scanning javaClass.methods on every capture is a full array walk per
    // Compose host; resolve once per (class, name), like SemanticsReflect does.
    private val methodCache = java.util.concurrent.ConcurrentHashMap<String, java.lang.reflect.Method>()

    private fun cachedMethod(target: Any, name: String): java.lang.reflect.Method? {
        val key = "${target.javaClass.name}#$name"
        methodCache[key]?.let { return it }
        val method = target.javaClass.methods.firstOrNull { it.name == name } ?: return null
        methodCache[key] = method
        return method
    }

    /**
     * If [view] is a Compose host, append composeSemantics child nodes under
     * [parentRef] and return their refs. Otherwise return an empty list.
     */
    fun captureInto(
        view: View,
        parentRef: String,
        nodes: MutableMap<String, Node>,
        makeRef: () -> String,
    ): List<String> {
        val className = view.javaClass.name
        if (!className.contains("AndroidComposeView")) return emptyList()

        return try {
            // AndroidComposeView.getSemanticsOwner(): SemanticsOwner
            val ownerMethod = cachedMethod(view, "getSemanticsOwner") ?: return emptyList()
            val owner = ownerMethod.invoke(view) ?: return emptyList()

            // SemanticsOwner.getRootSemanticsNode(): SemanticsNode
            val rootMethod = cachedMethod(owner, "getRootSemanticsNode") ?: return emptyList()
            val rootNode = rootMethod.invoke(owner) ?: return emptyList()

            // Compose reports bounds relative to the host window; View frames use
            // screen coordinates (getLocationOnScreen). Convert Compose bounds to
            // screen space by adding the host View's window origin so both trees
            // share one coordinate system (matters under status bars, dialogs,
            // and split-screen where window != screen origin).
            val onScreen = IntArray(2)
            val inWindow = IntArray(2)
            view.getLocationOnScreen(onScreen)
            view.getLocationInWindow(inWindow)
            val offsetX = (onScreen[0] - inWindow[0]).toDouble()
            val offsetY = (onScreen[1] - inWindow[1]).toDouble()

            val ref = visit(rootNode, parentRef, nodes, offsetX, offsetY, makeRef)
            if (ref != null) listOf(ref) else emptyList()
        } catch (_: Throwable) {
            emptyList()
        }
    }

    private fun visit(
        semanticsNode: Any,
        parentRef: String,
        nodes: MutableMap<String, Node>,
        offsetX: Double,
        offsetY: Double,
        makeRef: () -> String,
    ): String? {
        val ref = makeRef()

        val testTag = SemanticsReflect.testTag(semanticsNode)
        val text = SemanticsReflect.text(semanticsNode)
        val contentDescription = SemanticsReflect.contentDescription(semanticsNode)
        val frame = SemanticsReflect.boundsInWindow(semanticsNode)
            ?.let { it.copy(x = it.x + offsetX, y = it.y + offsetY) }
        val role = SemanticsReflect.role(semanticsNode) ?: "composable"

        val childRefs = ArrayList<String>()
        for (child in SemanticsReflect.children(semanticsNode)) {
            visit(child, ref, nodes, offsetX, offsetY, makeRef)?.let(childRefs::add)
        }

        nodes[ref] = Node(
            ref = ref,
            parentRef = parentRef,
            kind = NodeKind.composeSemantics,
            typeName = "ComposeSemanticsNode",
            role = role,
            contentDescription = contentDescription,
            text = text,
            testId = testTag,
            frame = frame,
            isVisible = frame == null || (frame.width > 0 && frame.height > 0),
            isInteractive = SemanticsReflect.hasClickAction(semanticsNode),
            custom = buildMap {
                testTag?.let { tag ->
                    ReticleRuntime.shared.metadata(tag).forEach { (k, v) -> put(k, v) }
                }
            } as Map<String, MetadataValue>,
            children = childRefs,
        )
        return ref
    }
}
