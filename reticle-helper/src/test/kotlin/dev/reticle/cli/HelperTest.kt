package dev.reticle.cli

import dev.reticle.core.ReticleJson
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The stdio RPC envelope contract from [Helper]: a malformed or unrecognized
 * request must produce an `ok:false` response, never a crash — so one bad call
 * can't take the long-lived helper down mid-session. Covers the header cases
 * that don't touch a device (device-backed methods need real adb).
 */
class HelperTest {

    private fun handle(line: String) = ReticleJson.compact.parseToJsonElement(Helper.handleLine(line)).jsonObject

    @Test
    fun malformedJsonYieldsErrorWithIdMinusOne() {
        val r = handle("{ not json")
        assertEquals(-1, r["id"]!!.jsonPrimitive.int)
        assertFalse(r["ok"]!!.jsonPrimitive.boolean)
    }

    @Test
    fun missingMethodYieldsErrorButKeepsId() {
        val r = handle("""{"id":7}""")
        assertEquals(7, r["id"]!!.jsonPrimitive.int)
        assertFalse(r["ok"]!!.jsonPrimitive.boolean)
        assertTrue(r["error"]!!.jsonPrimitive.content.contains("method"))
    }

    @Test
    fun unknownMethodYieldsError() {
        val r = handle("""{"id":3,"method":"definitelyNotAMethod"}""")
        assertEquals(3, r["id"]!!.jsonPrimitive.int)
        assertFalse(r["ok"]!!.jsonPrimitive.boolean)
        assertTrue(r["error"]!!.jsonPrimitive.content.contains("definitelyNotAMethod"))
    }

    @Test
    fun typeMismatchedEnvelopeFieldsYieldErrorsNotCrashes() {
        // Well-formed JSON with wrong-typed envelope fields must be answered,
        // not thrown: any escape here kills the long-lived serve() loop.
        val fractionalId = handle("""{"id":1.5,"method":"ping"}""")
        assertEquals(-1, fractionalId["id"]!!.jsonPrimitive.int)
        assertTrue(fractionalId["ok"]!!.jsonPrimitive.boolean)

        val objectId = handle("""{"id":{},"method":"ping"}""")
        assertEquals(-1, objectId["id"]!!.jsonPrimitive.int)

        val objectMethod = handle("""{"id":4,"method":{}}""")
        assertEquals(4, objectMethod["id"]!!.jsonPrimitive.int)
        assertFalse(objectMethod["ok"]!!.jsonPrimitive.boolean)
        assertTrue(objectMethod["error"]!!.jsonPrimitive.content.contains("method"))

        val numericMethod = handle("""{"id":4,"method":5}""")
        assertFalse(numericMethod["ok"]!!.jsonPrimitive.boolean)

        val scalarParams = handle("""{"id":9,"method":"ping","params":5}""")
        assertEquals(9, scalarParams["id"]!!.jsonPrimitive.int)
        assertFalse(scalarParams["ok"]!!.jsonPrimitive.boolean)
        assertTrue(scalarParams["error"]!!.jsonPrimitive.content.contains("params"))

        val arrayParams = handle("""{"id":9,"method":"ping","params":[1]}""")
        assertFalse(arrayParams["ok"]!!.jsonPrimitive.boolean)
    }

    @Test
    fun pingSucceedsWithoutADevice() {
        val r = handle("""{"id":1,"method":"ping"}""")
        assertEquals(1, r["id"]!!.jsonPrimitive.int)
        assertTrue(r["ok"]!!.jsonPrimitive.boolean)
        val result = r["result"]!!.jsonObject
        assertTrue(result["pong"]!!.jsonPrimitive.boolean)
        assertEquals(RETICLE_VERSION, result["version"]!!.jsonPrimitive.content)
    }

    @Test
    fun aBadCallDoesNotAffectSurroundingCalls() {
        // handleLine is pure per-line, so a garbage line between two good ones
        // can't corrupt them — the property serve()'s loop relies on.
        assertTrue(handle("""{"id":1,"method":"ping"}""")["ok"]!!.jsonPrimitive.boolean)
        assertFalse(handle("garbage")["ok"]!!.jsonPrimitive.boolean)
        assertTrue(handle("""{"id":2,"method":"ping"}""")["ok"]!!.jsonPrimitive.boolean)
    }
}
