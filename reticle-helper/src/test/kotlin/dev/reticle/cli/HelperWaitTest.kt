package dev.reticle.cli

import dev.reticle.core.WaitPredicateKind
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * `act wait`'s argument surface on the Android side.
 *
 * The classification is pinned by the shared fixture table (reticle-core's
 * WaitClassificationTest) and the poll loop by the Swift host's IosWaitTests;
 * what needs Kotlin-side coverage is [HelperWait.predicateFrom] — which spellings
 * are accepted, which are refused, and that the refusals match the iOS host's
 * word for word, since a predicate accepted on one platform and rejected on the
 * other is the drift this feature can least afford.
 */
class HelperWaitTest {

    private fun params(build: (kotlinx.serialization.json.JsonObjectBuilder) -> Unit): JsonObject =
        buildJsonObject { build(this) }

    @Test
    fun forTokenReusesTheVerifyGrammar() {
        // One spelling to learn, shared with `--verify`.
        assertEquals(
            "appear testId=cart.total",
            HelperWait.predicateFrom(params { it.put("for", "#cart.total") }).describe(),
        )
        assertEquals(
            "appear resourceId=status",
            HelperWait.predicateFrom(params { it.put("for", "@status") }).describe(),
        )
        assertEquals(
            "appear css=#pay",
            HelperWait.predicateFrom(params { it.put("for", "css=#pay") }).describe(),
        )
        assertEquals(
            "appear testId=x",
            HelperWait.predicateFrom(params { it.put("for", "testId=x") }).describe(),
        )
        assertEquals(
            "appear ref=r7",
            HelperWait.predicateFrom(params { it.put("for", "r7") }).describe(),
        )
    }

    @Test
    fun ordinarySelectorFlagsWorkToo() {
        assertEquals(
            "appear testId=cart.total",
            HelperWait.predicateFrom(params { it.put("testId", "cart.total") }).describe(),
        )
        assertEquals(
            "appear label=Delete item",
            HelperWait.predicateFrom(params { it.put("label", "Delete item") }).describe(),
        )
    }

    @Test
    fun goneAndTextSelectTheirPredicateKinds() {
        val gone = HelperWait.predicateFrom(params { it.put("testId", "toast"); it.put("gone", true) })
        assertEquals(WaitPredicateKind.gone, gone.kind)
        val text = HelperWait.predicateFrom(
            params { it.put("testId", "status"); it.put("textContains", "Paid") }
        )
        assertEquals(WaitPredicateKind.text, text.kind)
        assertEquals("Paid", text.textContains)
        assertEquals("text testId=status contains \"Paid\"", text.describe())
    }

    @Test
    fun idleIsSpelledTwoWaysAndTakesNoSelector() {
        assertEquals(WaitPredicateKind.idle, HelperWait.predicateFrom(params { it.put("idle", true) }).kind)
        assertEquals(WaitPredicateKind.idle, HelperWait.predicateFrom(params { it.put("for", "idle") }).kind)
        // A selector plus --idle is a contradiction: idle watches the whole screen.
        val error = assertFailsWith<CliError> {
            HelperWait.predicateFrom(params { it.put("idle", true); it.put("testId", "x") })
        }
        assertTrue(error.message!!.contains("takes no selector"), "message was: ${error.message}")
    }

    @Test
    fun refusesAPredicateItCouldNotAnswer() {
        // A bare point always "resolves", so waiting on one is meaningless.
        val point = assertFailsWith<CliError> {
            HelperWait.predicateFrom(params { it.put("point", "10,20") })
        }
        assertTrue(point.message!!.contains("--point"), "message was: ${point.message}")

        // An outline alias describes the screen it was captured on — which is the
        // screen a wait exists to watch change.
        val alias = assertFailsWith<CliError> {
            HelperWait.predicateFrom(params { it.put("testId", "x"); it.put("alias", "@1") })
        }
        assertTrue(alias.message!!.contains("--alias"), "message was: ${alias.message}")

        // No predicate at all.
        val empty = assertFailsWith<CliError> { HelperWait.predicateFrom(params { }) }
        assertTrue(empty.message!!.contains("needs a predicate"), "message was: ${empty.message}")

        // Two predicates at once.
        assertFailsWith<CliError> {
            HelperWait.predicateFrom(
                params { it.put("testId", "x"); it.put("gone", true); it.put("textContains", "y") }
            )
        }
    }

    @Test
    fun anUnknownForTokenFailsLoudly() {
        // Falling through to a never-matching ref would make every such wait report
        // a confident, wrong "absent" — the same bug --verify's token parser had.
        assertFailsWith<CliError> { HelperWait.predicateFrom(params { it.put("for", "bogus=1") }) }
    }
}
