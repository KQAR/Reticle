package dev.reticle.cli

import dev.reticle.core.Point
import dev.reticle.core.ReticleJson
import dev.reticle.core.Selector
import dev.reticle.core.SemanticTree
import dev.reticle.core.Snapshot
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * The action path's selector-resolution table, driven by the SAME
 * language-neutral fixture the Swift suite reads:
 * reticle-protocol/fixtures/selector-resolution.cases.json.
 *
 * Why a fixture rather than inline cases: the iOS resolver is Swift
 * (`ReticleProtocol.SelectorResolution`), so one file has to drive both or they
 * drift — and they had, in seven ways, including a `--region` miss that tapped
 * the whole node here while failing loudly there.
 */
class SelectorResolutionContractTest {

    /**
     * The fixture wrapper is walked as raw JSON rather than modelled with
     * `@Serializable` classes: reticle-helper deliberately does not apply the
     * serialization compiler plugin (it has no wire types of its own, and the
     * native-image build depends on compile-time serializers only coming from
     * core). `Snapshot` and `Selector` still decode through their own generated
     * serializers, so the fixture is parsed by the real protocol code.
     */
    private data class Case(
        val name: String,
        val selector: Selector,
        val expected: String,
    )

    private fun fixture(): Pair<Snapshot, List<Case>> {
        val text = javaClass.classLoader
            .getResourceAsStream("fixtures/selector-resolution.cases.json")
            ?.bufferedReader()?.readText()
            ?: fail("missing fixtures/selector-resolution.cases.json on the test classpath")
        val root = ReticleJson.instance.parseToJsonElement(text).jsonObject
        val snapshot = ReticleJson.instance.decodeFromJsonElement(
            Snapshot.serializer(), root.getValue("snapshot")
        )
        val cases = root.getValue("cases").jsonArray.map { element ->
            val obj = element.jsonObject
            Case(
                name = obj.getValue("name").jsonPrimitive.content,
                selector = ReticleJson.instance.decodeFromJsonElement(
                    Selector.serializer(), obj.getValue("selector")
                ),
                expected = expected(obj.getValue("expect").jsonObject),
            )
        }
        return snapshot to cases
    }

    /** Renders a fixture `expect` block into the same one-line shape as an actual. */
    private fun expected(expect: JsonObject): String {
        expect["error"]?.let { return "error:${it.jsonPrimitive.content}" }
        if (expect["miss"]?.jsonPrimitive?.booleanOrNull == true) return "miss"
        val point = expect["point"]?.jsonObject ?: return "<malformed case>"
        val source = expect["source"]?.jsonPrimitive?.content ?: return "<malformed case>"
        val x = point.getValue("x").jsonPrimitive.double
        val y = point.getValue("y").jsonPrimitive.double
        val ref = expect["ref"]?.jsonPrimitive?.contentOrNull ?: "nil"
        return "$source @${fmt(Point(x, y))} ref=$ref"
    }

    @Test
    fun everyFixtureCaseResolvesAsSpecified() {
        val (snapshot, cases) = fixture()
        val resolver = SelectorResolver(snapshot, SemanticTree.build(snapshot))
        val failures = mutableListOf<String>()

        for (case in cases) {
            val actual = try {
                val resolved = resolver.resolve(case.selector)
                if (resolved == null) "miss"
                else "${resolved.source} @${fmt(resolved.point)} ref=${resolved.ref ?: "nil"}"
            } catch (e: RegionMissError) {
                "error:regionMiss"
            } catch (e: CliError) {
                "error:ambiguousLabel"
            }
            if (actual != case.expected) {
                failures += "  - ${case.name}\n      expected ${case.expected}\n      actual   $actual"
            }
        }

        assertTrue(
            failures.isEmpty(),
            "selector resolution disagreed with the shared fixture:\n" + failures.joinToString("\n")
        )
    }

    /**
     * Resolution must not depend on the order the agent serialized its node map
     * in. Re-serializing the snapshot with reversed keys must not move the answer
     * for a duplicated testId — the Swift twin had this randomized per process.
     */
    @Test
    fun duplicateIdResolutionIgnoresNodeMapOrder() {
        val (snapshot, _) = fixture()
        val reversed = snapshot.copy(
            nodes = snapshot.nodes.entries.reversed().associate { it.key to it.value }
        )
        for (candidate in listOf(snapshot, reversed)) {
            val resolved = SelectorResolver(candidate, SemanticTree.build(candidate))
                .resolve(Selector(testId = "dup.button"))
            assertEquals("n2", resolved?.ref, "duplicate testId must resolve to the first in document order")
        }
    }

    private fun fmt(p: Point) = "%.1f,%.1f".format(p.x, p.y)
}
