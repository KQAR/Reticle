package dev.reticle.core

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * `MetadataValue.displayString()` feeds `verify --custom` matching and trace
 * diffs, so a `real` has to spell the same on both agents. This table is the
 * twin of `MetadataRealFormatTests` in reticle-swift: the Swift side re-dresses
 * its `String(Double)` output to reach exactly these strings, so if a runtime
 * ever changes its mind one of the two suites fails.
 */
class MetadataRealFormatTest {
    @Test
    fun `real spellings are the canonical ones`() {
        val table = listOf(
            0.0 to "0.0",
            -0.0 to "-0.0",
            1.0 to "1.0",
            -1.0 to "-1.0",
            3.5 to "3.5",
            1234.5 to "1234.5",
            0.001 to "0.001",
            -0.001 to "-0.001",
            0.0001 to "1.0E-4",
            1e-5 to "1.0E-5",
            1.5e-7 to "1.5E-7",
            9999999.0 to "9999999.0",
            1e7 to "1.0E7",
            1.23e10 to "1.23E10",
            1e17 to "1.0E17",
            -1e17 to "-1.0E17",
            1.7976931348623157e308 to "1.7976931348623157E308",
            Double.POSITIVE_INFINITY to "Infinity",
            Double.NEGATIVE_INFINITY to "-Infinity",
            Double.NaN to "NaN",
        )
        for ((value, expected) in table) {
            assertEquals(expected, MetadataValue.Real(value).displayString(), "spelling of $value")
        }
    }
}
