package dev.reticle.cli

import dev.reticle.core.Render
import dev.reticle.core.ReticleJson
import dev.reticle.core.Snapshot
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * The `ui <view>` roster, against this port — driven by the language-neutral
 * fixture reticle-protocol/fixtures/render-views.cases.json, which the Swift suite
 * (`RenderViewRosterTests`) reads too.
 *
 * The CLI advertises ONE list of views for every target, so a view is either
 * rendered by the port or refused by a reason that names the boundary. The third
 * outcome — falling through to "unknown render view", an internal error wearing a
 * user-facing message — is what both suites forbid. It is not hypothetical:
 * `ui outline --target ios` answered exactly that way, naming no boundary and
 * suggesting no path, because `outline` is this helper's own alias cache and the
 * Swift host had no case for it at all.
 */
class RenderViewRosterTest {

    private data class ViewCase(
        val name: String,
        val platforms: List<String>,
        val refusalMentions: List<String>,
    )

    // Parsed by hand rather than through @Serializable: this module does not apply
    // the kotlinx-serialization compiler plugin (it only consumes reticle-core's
    // generated serializers), and adding it for one test fixture would be a build
    // change to buy nothing.
    private fun roster(): List<ViewCase> {
        val text = javaClass.classLoader
            .getResourceAsStream("fixtures/render-views.cases.json")
            ?.bufferedReader()?.readText()
            ?: fail("missing fixtures/render-views.cases.json on the test classpath")
        return ReticleJson.instance.parseToJsonElement(text).jsonObject
            .getValue("views").jsonArray
            .map { it.jsonObject }
            .map { view ->
                ViewCase(
                    name = view.getValue("name").jsonPrimitive.content,
                    platforms = view.getValue("platforms").jsonArray.map { it.jsonPrimitive.content },
                    refusalMentions = view["refusalMentions"]?.jsonArray
                        ?.map { it.jsonPrimitive.content }.orEmpty(),
                )
            }
    }

    private fun golden(): Snapshot {
        val text = javaClass.classLoader
            .getResourceAsStream("fixtures/snapshot.golden.json")
            ?.bufferedReader()?.readText()
            ?: fail("missing fixtures/snapshot.golden.json on the test classpath")
        return ReticleJson.instance.decodeFromString(Snapshot.serializer(), text)
    }

    @Test
    fun theRosterConstantMatchesTheSharedFixture() {
        assertEquals(
            roster().map { it.name },
            Render.ROSTER,
            "Render.ROSTER and render-views.cases.json are the same list, in the same order",
        )
    }

    @Test
    fun everyAndroidRosterViewIsHandled() {
        val snapshot = golden()
        for (view in roster().filter { "android" in it.platforms }) {
            try {
                HelperRenderCommands.renderView(view.name, snapshot, JsonObject(emptyMap()))
            } catch (e: Throwable) {
                // `node` and `style` need a selector this smoke call does not pass, so
                // reaching their own argument error is proof they are implemented. What
                // must never appear is the dispatcher's fall-through.
                val message = e.message ?: ""
                assertFalse(
                    message.contains("unknown render view"),
                    "'${view.name}' is on the roster and fell through the helper's dispatch: $message",
                )
            }
        }
    }

    /**
     * The other half of the same contract: a view this port does NOT implement must
     * be listed as such, so the Swift suite can hold its refusal to a named reason.
     * Today that is only `outline`.
     */
    @Test
    fun aViewMissingAPlatformDeclaresWhatItsRefusalMustSay() {
        for (view in roster().filter { it.platforms.size < 2 }) {
            assertTrue(
                view.refusalMentions.isNotEmpty(),
                "'${view.name}' renders on only ${view.platforms} and must state what its " +
                    "refusal on the other platform has to mention — a boundary with no wording " +
                    "requirement is a boundary that degrades back into a generic error",
            )
        }
    }
}
