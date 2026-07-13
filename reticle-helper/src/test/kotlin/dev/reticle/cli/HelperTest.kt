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
