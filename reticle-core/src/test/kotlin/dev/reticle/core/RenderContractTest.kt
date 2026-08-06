package dev.reticle.core

import kotlinx.serialization.Serializable
import kotlin.test.Test
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * The text projections an agent reads (`ui compact`, `ui tree`,
 * `ui tree --semantics`, `ui regions`), driven by the language-neutral fixture at
 * reticle-protocol/fixtures/snapshot-render.cases.json.
 *
 * Why a fixture rather than inline cases: the iOS path renders through Swift, so
 * the same file drives ReticleProtocol's `RenderContractTests`. Before this
 * existed, `compact` was rendered by the Kotlin helper and by ReticleProtocol
 * independently, pinned only by hand-mirrored unit tests that had to be
 * remembered — and `compact` had already drifted that way once. The derivation
 * was shared; the formatting was not.
 */
class RenderContractTest {

    @Serializable
    private data class Case(
        val name: String,
        val expect: Map<String, List<String>>,
        val snapshot: Snapshot,
    )

    @Serializable
    private data class Cases(val cases: List<Case>)

    private fun cases(): List<Case> {
        val text = javaClass.classLoader
            .getResourceAsStream("fixtures/snapshot-render.cases.json")
            ?.bufferedReader()?.readText()
            ?: fail("missing fixtures/snapshot-render.cases.json on the test classpath")
        return ReticleJson.instance.decodeFromString(Cases.serializer(), text).cases
    }

    private fun render(view: String, snapshot: Snapshot): List<String> = when (view) {
        "compact" -> Render.compact(snapshot)
        "tree" -> Render.tree(snapshot)
        "semantics" -> Render.semantics(SemanticTree.build(snapshot))
        "regions" -> Render.regions(snapshot)
        else -> fail("fixture asks for an unknown view '$view'")
    }.lines()

    @Test
    fun everyFixtureCaseRendersAsSpecified() {
        val failures = ArrayList<String>()
        for (case in cases()) {
            for ((view, expect) in case.expect) {
                val actual = render(view, case.snapshot)
                if (actual != expect) {
                    failures.add(
                        "  - ${case.name} [$view]\n" +
                            "      expected:\n" + expect.joinToString("\n") { "        $it" } + "\n" +
                            "      actual:\n" + actual.joinToString("\n") { "        $it" }
                    )
                }
            }
        }
        if (failures.isNotEmpty()) {
            fail("text projections diverged from the fixture:\n" + failures.joinToString("\n"))
        }
    }

    @Test
    fun fixtureCoversTheFactsNoNodeCarries() {
        // The screen-level lines are the ones a renderer can lose silently: drop
        // the focus line and a screen behind a permission prompt reads as
        // ordinary; drop the keyboard line and covered items read as tappable;
        // drop the fold footer and a token-cheap view reads as the whole tree.
        val rendered = cases().flatMap { it.expect.values.flatten() }
        assertTrue(rendered.any { it.startsWith("window: UNFOCUSED") }, "no case renders lost window focus")
        assertTrue(rendered.any { it.startsWith("keyboard: visible") }, "no case renders a visible keyboard")
        assertTrue(rendered.any { it.startsWith("keyboard: hidden") }, "no case renders a hidden keyboard")
        assertTrue(rendered.any { it.contains("anonymous layer(s) folded") }, "no case renders the fold footer")
        assertTrue(rendered.any { it.startsWith("window ") && it.endsWith("[top]") }, "no case renders window grouping")
        assertTrue(rendered.any { it.contains("occluded-by:keyboard") }, "no case renders keyboard occlusion")
    }

    @Test
    fun fixtureCoversEveryBoundaryMarker() {
        // Each of these is a boundary from docs/boundaries.md whose whole purpose is
        // to be VISIBLE. A marker that stops rendering turns an unreachable thing
        // back into a silent absence, which is the one failure the boundary table
        // exists to prevent.
        val rendered = cases().flatMap { it.expect.values.flatten() }
        for (marker in listOf(
            "dom:unavailable",
            "dom:unsupported-kernel",
            "pixels:unavailable",
            "screencap:blank",
            "wheel:selection-only",
            "wheel:opaque",
            "scroll:",
            // The three frame walls are one marker family and must stay three: they
            // ask a caller for opposite moves (coordinates / fix the page / retry),
            // and collapsing any two of them is the defect this family exists to fix.
            "iframe:cross-origin",
            "iframe:sandboxed",
            "iframe:not-loaded",
            // The wall and the READER's own limit are two markers on purpose: one says
            // what the page allows, the other whether the mechanism that can cross it
            // got a turn. A frame that loaded before the probe existed is the second.
            "iframe:probe-needs-reload",
            "geometry:approx",
        )) {
            assertTrue(rendered.any { it.contains(marker) }, "no case renders '$marker'")
        }
    }

    @Test
    fun fixtureCoversBothPlatforms() {
        val cases = cases()
        assertTrue(cases.any { it.snapshot.platform == "android" }, "no android case")
        assertTrue(cases.any { it.snapshot.platform == "ios" }, "no iOS case")
    }

    @Test
    fun theSemanticProjectionIsOrderedByTheTreeNotByTheNodeMap() {
        // `SemanticTree.build` used to insert kept nodes in HashSet order, which
        // decided both the map's order and the synthesized root's child list — so a
        // tree with several top-level kept nodes printed in an order the Swift twin
        // (which walks the tree) did not share. Pin the walk, not the hash.
        val nodes = listOf("d", "b", "c", "a").map { ref ->
            Node(
                ref = ref,
                parentRef = "root",
                kind = NodeKind.view,
                typeName = "android.widget.Button",
                role = "button",
                testId = "btn.$ref",
                frame = Rect(0.0, 0.0, 10.0, 10.0),
                isInteractive = true,
            )
        }
        val root = Node(
            ref = "root",
            kind = NodeKind.application,
            typeName = "android.app.Application",
            role = "application",
            children = nodes.map { it.ref },
        )
        val snapshot = Snapshot(
            capturedAtMillis = 0,
            screen = ScreenInfo(Size(1080.0, 2400.0), 3.0),
            rootRef = "root",
            nodes = (nodes + root).associateBy { it.ref },
        )
        val tree = SemanticTree.build(snapshot)
        kotlin.test.assertEquals(listOf("d", "b", "c", "a"), tree.nodes.getValue("root").children)
    }
}
