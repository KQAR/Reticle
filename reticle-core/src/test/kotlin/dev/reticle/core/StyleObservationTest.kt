package dev.reticle.core

import kotlinx.serialization.Serializable
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * The style projection's output table, driven by the language-neutral fixture at
 * reticle-protocol/fixtures/style-observation.cases.json.
 *
 * The point of reading a fixture instead of writing the cases inline: the iOS
 * path renders through Swift, so the same file drives ReticleProtocol's suite. A
 * change to a unit conversion or a line format that is made on one side only
 * fails here or there — which is exactly how the two `compact` renderers, and
 * `scroll-to`'s settle logic before them, drifted.
 *
 * The conversions worth naming, because getting either wrong is silent:
 * an Android length is physical pixels and divides by density, while a UIKit
 * length is points and must NOT be divided again; and sp needs `fontScale`, whose
 * absence is reported rather than assumed to be 1.0.
 */
class StyleObservationTest {

    @Serializable
    private data class Case(
        val name: String,
        val snapshot: Snapshot,
        val expect: List<String>,
    )

    @Serializable
    private data class Cases(val cases: List<Case>)

    private fun cases(): List<Case> {
        val text = javaClass.classLoader
            .getResourceAsStream("fixtures/style-observation.cases.json")
            ?.bufferedReader()?.readText()
            ?: fail("missing fixtures/style-observation.cases.json on the test classpath")
        return ReticleJson.instance.decodeFromString(Cases.serializer(), text).cases
    }

    @Test
    fun everyFixtureCaseRendersAsSpecified() {
        val failures = ArrayList<String>()
        for (case in cases()) {
            val actual = StyleObservation.from(case.snapshot).render().lines()
            if (actual != case.expect) {
                failures.add(
                    "  - ${case.name}\n" +
                        "      expected:\n" + case.expect.joinToString("\n") { "        $it" } + "\n" +
                        "      actual:\n" + actual.joinToString("\n") { "        $it" }
                )
            }
        }
        if (failures.isNotEmpty()) {
            fail("style projection diverged from the fixture:\n" + failures.joinToString("\n"))
        }
    }

    @Test
    fun fixtureCoversBothUnitSystemsAndAGap() {
        // A fixture that lost its iOS case would let the density-double-scaling bug
        // back in unnoticed, and one with no gap case would let the "unreadable
        // property looks absent" regression through. Assert the coverage itself.
        val cases = cases()
        assertTrue(cases.any { it.snapshot.platform == "android" }, "no android case")
        assertTrue(cases.any { it.snapshot.platform == "ios" }, "no iOS case")
        assertTrue(
            cases.any { c -> c.snapshot.nodes.values.any { it.styleGaps.isNotEmpty() } },
            "no case exercises styleGaps",
        )
        assertTrue(
            cases.any { it.snapshot.screen.fontScale == null },
            "no case exercises an unprobed fontScale",
        )
    }

    @Test
    fun styleChannelsIsTheAllowlistOfWhatCountsAsStyle() {
        // `tag` and `domCssSelector` live in `custom` but carry no channel, so they
        // must not appear in the projection: without this rule the style view would
        // slowly become a dump of every scalar the agent happens to reflect.
        val node = Node(
            ref = "r1",
            kind = NodeKind.view,
            typeName = "android.widget.TextView",
            custom = mapOf(
                "textSize" to MetadataValue.Real(42.0),
                "tag" to MetadataValue.Text("not-style"),
            ),
            styleChannels = mapOf("textSize" to StyleChannel.viewField),
        )
        val snapshot = Snapshot(
            capturedAtMillis = 0,
            screen = ScreenInfo(Size(1080.0, 2400.0), 3.0, fontScale = 1.0),
            rootRef = "r1",
            nodes = mapOf("r1" to node),
        )
        val item = StyleObservation.from(snapshot).items.single()
        assertEquals(listOf("textSize"), item.attributes.map { it.name })
    }

    @Test
    fun unknownPropertyNamesRenderVerbatimInsteadOfBeingConverted() {
        // A new capture surface must degrade to "shown as captured", never to a
        // wrong conversion — the reason the unit table maps names to kinds and
        // defaults to `opaque`.
        assertEquals(StyleUnit.opaque, StyleUnits.unitOf("someNewProperty"))
        val units = StyleUnits("android", ScreenInfo(Size(1080.0, 2400.0), 3.0, fontScale = 1.0))
        assertEquals("13.5", units.render("someNewProperty", MetadataValue.Real(13.5)))
    }
}
