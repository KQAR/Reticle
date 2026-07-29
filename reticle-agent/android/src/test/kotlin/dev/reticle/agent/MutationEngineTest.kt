package dev.reticle.agent

import dev.reticle.core.MetadataValue
import dev.reticle.core.MutationRequest
import dev.reticle.core.Selector
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The mutation allowlist. It is the whole safety story for patching a live app
 * from the CLI: without it this becomes an arbitrary reflective write into a
 * running process, which is exactly what the design refuses to be.
 */
@RunWith(RobolectricTestRunner::class)
class MutationEngineTest {

    private val engine = MutationEngine(RuntimeEnvironment.getApplication())

    private fun apply(property: String) = engine.apply(
        MutationRequest(selector = Selector(testId = "whatever"), property = property, value = MetadataValue.Text("x"))
    )

    @Test
    fun aPropertyOutsideTheAllowlistIsRefusedAndTheRefusalNamesIt() {
        for (property in listOf("onClickListener", "layoutParams", "translationX", "tag")) {
            val result = apply(property)
            assertFalse(result.applied, "'$property' must not be writable")
            val message = result.message ?: ""
            assertTrue(message.contains("allowlist"), message)
            assertTrue(message.contains(property), "the refusal should name what was refused: $message")
        }
    }

    @Test
    fun anAllowlistedPropertyGetsPastTheAllowlistAndFailsOnResolutionInstead() {
        // "Refused the property" and "could not find the view" must stay
        // distinguishable: collapsing them sends a caller with a typo'd selector
        // off to change the wrong thing.
        val result = apply("alpha")
        assertFalse(result.applied)
        val message = result.message ?: ""
        assertFalse(message.contains("allowlist"), message)
        assertTrue(message.contains("no view matched"), message)
    }

    @Test
    fun theAllowlistIsTheDocumentedSetAndComposeIsNotInIt() {
        // Compose nodes are deliberately immutable from outside — declarative UI
        // is driven through app-owned state, never patched. A new entry here
        // should be a decision, not a drive-by.
        for (property in listOf("alpha", "visibility", "text", "backgroundColor", "textColor", "textSize", "enabled")) {
            val message = apply(property).message ?: ""
            assertFalse(message.contains("allowlist"), "'$property' should be allowed: $message")
        }
    }

    @Test
    fun colorsAreRenderedAsAarrggbbInThatOrder() {
        // The wire format is #AARRGGBB (alpha FIRST), matching the iOS agent.
        // #RRGGBBAA here would make every cross-platform colour comparison wrong
        // in a way that still looks like a colour.
        assertEquals("#FFFF0000", ReticleReflect.colorHex(android.graphics.Color.RED))
        assertEquals("#80000000", ReticleReflect.colorHex(0x80000000.toInt()))
    }
}
