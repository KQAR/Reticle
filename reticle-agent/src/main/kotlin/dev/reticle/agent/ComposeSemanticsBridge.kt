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
            val ownerMethod = view.javaClass.methods.firstOrNull { it.name == "getSemanticsOwner" }
                ?: return emptyList()
            val owner = ownerMethod.invoke(view) ?: return emptyList()

            // SemanticsOwner.getRootSemanticsNode(): SemanticsNode
            val rootMethod = owner.javaClass.methods.firstOrNull { it.name == "getRootSemanticsNode" }
                ?: return emptyList()
            val rootNode = rootMethod.invoke(owner) ?: return emptyList()

            val ref = visit(rootNode, parentRef, nodes, makeRef)
            if (ref != null) listOf(ref) else emptyList()
        } catch (_: Throwable) {
            emptyList()
        }
    }

    private fun visit(
        semanticsNode: Any,
        parentRef: String,
        nodes: MutableMap<String, Node>,
        makeRef: () -> String,
    ): String? {
        val ref = makeRef()

        val testTag = SemanticsReflect.testTag(semanticsNode)
        val text = SemanticsReflect.text(semanticsNode)
        val contentDescription = SemanticsReflect.contentDescription(semanticsNode)
        val frame = SemanticsReflect.boundsInScreen(semanticsNode)
        val role = SemanticsReflect.role(semanticsNode) ?: "composable"

        val childRefs = ArrayList<String>()
        for (child in SemanticsReflect.children(semanticsNode)) {
            visit(child, ref, nodes, makeRef)?.let(childRefs::add)
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
