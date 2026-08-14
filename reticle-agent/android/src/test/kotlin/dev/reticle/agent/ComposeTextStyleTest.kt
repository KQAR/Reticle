package dev.reticle.agent

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import dev.reticle.core.MetadataValue
import dev.reticle.core.StyleChannel
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Compose text style, over a REAL `TextStyle`.
 *
 * The style itself is genuine Compose — which is the point, because the two things
 * that make this reflection hard are properties of the real classes and cannot be
 * faked:
 *
 *  - **mangled JVM names.** `TextStyle.getFontSize()` returns `TextUnit`, an inline
 *    value class, so its compiled name carries a `-XSAIIZE`-style suffix that
 *    differs between Compose builds. A stand-in with a plainly-named getter would
 *    pass while the real one was unreadable.
 *  - **unboxed value classes.** A non-null `TextUnit`/`Color` getter returns the
 *    packed primitive, not an object, so there is nothing to call methods on and
 *    the static `…-impl` helpers have to unpack it.
 *
 * Only the `TextLayoutResult` wrapper is a stand-in: building a real one needs a
 * measure pass with a font resolver, and `probe` reads exactly two things off it
 * (`layoutInput.style`). Everything under that is the real thing.
 *
 * What this guards is the reading a design question depends on. `ui style` on a
 * Compose screen answered NOTHING before this channel existed, and the failure mode
 * if it breaks is the same silence — a screen that reports no font size reads as a
 * screen that sets none.
 */
class ComposeTextStyleTest {

    /** Stands in for `TextLayoutResult`, whose only role here is to hold the input. */
    class FakeLayoutResult(private val input: FakeLayoutInput) {
        fun getLayoutInput(): FakeLayoutInput = input
    }

    class FakeLayoutInput(private val style: TextStyle) {
        fun getStyle(): TextStyle = style
    }

    private fun probe(
        style: TextStyle,
        densityScale: Float = 2f,
        fontScale: Float = 1f,
    ) = ComposeTextStyle.probe(FakeLayoutResult(FakeLayoutInput(style)), densityScale, fontScale)

    private fun real(result: ComposeTextStyle.Result, key: String): Double? =
        (result.values[key] as? MetadataValue.Real)?.value

    private fun text(result: ComposeTextStyle.Result, key: String): String? =
        (result.values[key] as? MetadataValue.Text)?.value

    @Test
    fun spSizesComeOutAsRenderedDevicePixels() {
        // The whole point of normalising: `textSize` has to mean the same number on
        // the Compose channel as on the TextView one, or a consumer must ask which
        // kind of node it is holding before it can compare anything.
        val result = probe(TextStyle(fontSize = 14.sp), densityScale = 2f, fontScale = 1f)

        assertEquals(28.0, real(result, "textSize"))
        assertEquals(StyleChannel.textLayout, result.channels["textSize"])
    }

    @Test
    fun theUsersFontScaleIsPartOfTheRenderedSize() {
        // A reading that ignored fontScale would report the authored size while the
        // screen showed something else — the exact "plausible and wrong" shape.
        assertEquals(42.0, real(probe(TextStyle(fontSize = 14.sp), densityScale = 2f, fontScale = 1.5f), "textSize"))
    }

    @Test
    fun anEmLineHeightIsResolvedAgainstTheFontSizeItIsRelativeTo() {
        // Em is a MULTIPLE, so it can only be read after fontSize — which is why
        // `probe` reads that one first. Reported as an absolute px like every other
        // length, since "1.5" alone is not a length.
        val result = probe(TextStyle(fontSize = 10.sp, lineHeight = 1.5.em), densityScale = 2f)

        assertEquals(20.0, real(result, "textSize"))
        assertEquals(30.0, real(result, "lineHeight"))
    }

    @Test
    fun anUnspecifiedSizeIsANamedGapRatherThanAZero() {
        // `TextStyle()` sets no size. Zero would be a claim about the design;
        // the gap is what `ui style` prints as `! textSize unreadable: …`.
        val result = probe(TextStyle())

        assertNull(result.values["textSize"])
        assertEquals("compose-textunit-unreadable", result.gaps["textSize"])
    }

    @Test
    fun colourIsReadThroughItsPackedRepresentation() {
        val result = probe(TextStyle(color = Color(0xFF1A73E8)))

        assertEquals("#FF1A73E8", text(result, "textColor"))
    }

    @Test
    fun theKeywordProperties() {
        val result = probe(
            TextStyle(
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold,
                fontStyle = FontStyle.Italic,
                textAlign = TextAlign.Center,
            )
        )

        assertEquals(700L, (result.values["fontWeight"] as? MetadataValue.Integer)?.value)
        assertEquals("italic", text(result, "fontStyle"))
        assertEquals("center", text(result, "textAlign"))
    }

    @Test
    fun everyValueReadNamesTheChannelItCameFrom() {
        // `StyleChannel` is how a consumer knows a value was MEASURED rather than
        // guessed; a value with no channel is indistinguishable from an invention.
        val result = probe(TextStyle(fontSize = 12.sp, color = Color.Red, fontWeight = FontWeight.Medium))

        assertTrue(result.values.isNotEmpty())
        assertEquals(result.values.keys, result.channels.keys)
        assertTrue(result.channels.values.all { it == StyleChannel.textLayout })
    }

    @Test
    fun noLayoutMeansNoReadingAndNoGap() {
        // Nothing was asked, so nothing is claimed — a gap here would say "this text
        // has a size no channel can read", which is a different and false statement.
        val empty = ComposeTextStyle.probe(null, 2f, 1f)

        assertTrue(empty.values.isEmpty())
        assertTrue(empty.gaps.isEmpty())
    }

    @Test
    fun aLayoutThatCannotProduceAStyleIsAGapNotAnAbsence() {
        // The layout result IS there, so this text certainly HAS a style. Failing to
        // reach it is a Reticle-side gap and has to read as one.
        class Styleless { fun getLayoutInput(): Any = Any() }

        val result = ComposeTextStyle.probe(Styleless(), 2f, 1f)

        assertTrue(result.values.isEmpty())
        assertEquals("compose-textstyle-unreadable", result.gaps["textSize"])
    }

    @Test
    fun aShapeThatIsNotALayoutResultAtAllDegradesQuietly() {
        val result = ComposeTextStyle.probe("not a layout result", 2f, 1f)

        assertTrue(result.values.isEmpty())
        assertTrue(result.gaps.isEmpty())
    }
}
