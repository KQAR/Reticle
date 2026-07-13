package dev.reticle.cli

import dev.reticle.core.MetadataValue
import dev.reticle.core.ReticleJson
import kotlinx.serialization.json.jsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

/** Input parsing shared by every helper RPC command (HelperJson.kt). */
class HelperJsonTest {

    @Test
    fun parseValueInfersTypeInOrder() {
        // bool before long before double before text — the precedence callers rely on.
        assertEquals(MetadataValue.Bool(true), parseValue("true"))
        assertEquals(MetadataValue.Bool(false), parseValue("false"))
        assertEquals(MetadataValue.Integer(42L), parseValue("42"))
        assertEquals(MetadataValue.Real(1.5), parseValue("1.5"))
        assertEquals(MetadataValue.Text("hello"), parseValue("hello"))
        // "07" is a valid Long, so it stays numeric, not text.
        assertEquals(MetadataValue.Integer(7L), parseValue("07"))
    }

    @Test
    fun parseXYSplitsAndTrims() {
        assertEquals(10 to 20, parseXY("10,20"))
        assertEquals(10 to 20, parseXY(" 10 , 20 "))
        assertFailsWith<CliError> { parseXY("10") }
        assertFailsWith<CliError> { parseXY("10,20,30") }
    }

    @Test
    fun selectorFromMapsSupportedFields() {
        val params = ReticleJson.compact
            .parseToJsonElement("""{"testId":"pay","region":"Terms","point":"5,6"}""")
            .jsonObject
        val sel = selectorFrom(params)
        assertEquals("pay", sel.testId)
        assertEquals("Terms", sel.region)
        assertEquals(5.0, sel.point?.x)
        assertEquals(6.0, sel.point?.y)
    }
}
