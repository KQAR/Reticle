package dev.reticle.agent

import android.graphics.Color
import android.text.SpannableString
import android.text.Spanned
import android.text.style.ClickableSpan
import android.text.style.ForegroundColorSpan
import android.text.style.URLSpan
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView
import dev.reticle.core.RegionSource
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The region channels over REAL framework objects: a real [TextView] holding a
 * real [Spanned], laid out by the real `android.text.Layout` that every rect here
 * is derived from. Robolectric is what makes that possible on the JVM — the same
 * choice the iOS half makes by running its tests on a simulator rather than
 * against mocks. A faked `Layout` would only test the fake, and the geometry IS
 * the feature.
 *
 * The assertions are about which channel fired, what it labelled, and whether the
 * rect it produced lands inside the text it claims — not exact pixels, which move
 * with the font the runtime happens to use.
 */
@RunWith(RobolectricTestRunner::class)
class RegionProbeTest {

    private val context = RuntimeEnvironment.getApplication()

    /** A laid-out TextView, so `getLayout()` is non-null and geometry is real. */
    private fun textView(width: Int = 600, configure: TextView.() -> Unit): TextView {
        val tv = TextView(context)
        tv.textSize = 16f
        tv.configure()
        val spec = View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.AT_MOST)
        tv.measure(spec, View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
        tv.layout(0, 0, tv.measuredWidth, tv.measuredHeight)
        return tv
    }

    private fun clickable() = object : ClickableSpan() {
        override fun onClick(widget: View) = Unit
    }

    // --- Channel 1: spans -------------------------------------------------

    @Test
    fun aUrlSpanBecomesASpanRegionCarryingItsTargetAndRange() {
        val text = SpannableString("I agree to the Terms and the Privacy Policy")
        val start = text.indexOf("Terms")
        text.setSpan(URLSpan("https://example.com/terms"), start, start + 5, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        val tv = textView { setText(text, TextView.BufferType.SPANNABLE) }

        val region = RegionProbe.probe(tv).regions.single { it.source == RegionSource.span }
        assertEquals("Terms", region.label)
        assertEquals("https://example.com/terms", region.target)
        assertEquals(start, region.charStart)
        assertEquals(start + 5, region.charEnd)
        val rect = region.rects.first()
        assertTrue(rect.width > 0 && rect.height > 0, "a span with no rect is not addressable")
    }

    @Test
    fun twoLinksInOneRowResolveToTwoDistinctPoints() {
        // The agreement row: one node, two targets. Collapsing them into one
        // point is the failure this channel exists to prevent — the tap opens
        // the wrong document while looking like it worked.
        val text = SpannableString("Read the Terms and the Privacy Policy")
        text.setSpan(URLSpan("https://e/t"), 9, 14, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        text.setSpan(URLSpan("https://e/p"), 23, 37, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        val tv = textView { setText(text, TextView.BufferType.SPANNABLE) }

        val spans = RegionProbe.probe(tv).regions.filter { it.source == RegionSource.span }
        assertEquals(2, spans.size)
        assertEquals(setOf("https://e/t", "https://e/p"), spans.mapNotNull { it.target }.toSet())
        val points = spans.mapNotNull { it.tapPoint() }
        assertEquals(2, points.size)
        assertTrue(points[0].x != points[1].x, "two links resolved to the same tap point")
    }

    @Test
    fun aClickableSpanWithNoColorOfItsOwnReportsTheViewsLinkTint() {
        // The tint is on the VIEW (android:textColorLink), not in the span, so a
        // probe that only read spans reported no colour for the commonest case.
        val text = SpannableString("Read the Terms")
        text.setSpan(clickable(), 9, 14, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        val tv = textView {
            setText(text, TextView.BufferType.SPANNABLE)
            setLinkTextColor(Color.parseColor("#FF008577"))
        }

        val region = RegionProbe.probe(tv).regions.single { it.source == RegionSource.span }
        assertEquals("#FF008577", region.color)
    }

    @Test
    fun aForegroundColorSpanOnTheSameRangeWinsOverTheLinkTint() {
        val text = SpannableString("Read the Terms")
        text.setSpan(clickable(), 9, 14, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        text.setSpan(ForegroundColorSpan(Color.parseColor("#FF1A73E8")), 9, 14, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        val tv = textView {
            setText(text, TextView.BufferType.SPANNABLE)
            setLinkTextColor(Color.parseColor("#FF008577"))
        }

        val region = RegionProbe.probe(tv).regions.single { it.source == RegionSource.span }
        assertEquals("#FF1A73E8", region.color, "an explicit run colour is what actually renders")
    }

    // --- Channel 3b: re-coloured runs -------------------------------------

    @Test
    fun aRecoloredRunWithNoClickableSpanIsSurfacedAsAColorCandidate() {
        // "Colour the phrase, hit-test it in one OnClickListener" — there is no
        // span to find, so colour is the only signal the tree carries.
        val text = SpannableString("By continuing you accept the Privacy Policy")
        val start = text.indexOf("Privacy Policy")
        text.setSpan(ForegroundColorSpan(Color.parseColor("#FF1A73E8")), start, text.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        val tv = textView { setText(text, TextView.BufferType.SPANNABLE) }

        val region = RegionProbe.probe(tv).regions.single { it.source == RegionSource.colorSpan }
        assertEquals("Privacy Policy", region.label)
        assertEquals("#FF1A73E8", region.color)
        assertTrue(region.rects.first().width > 0)
    }

    @Test
    fun aRunAlreadyCoveredByAClickableSpanIsNotReportedTwice() {
        val text = SpannableString("Read the Terms")
        text.setSpan(clickable(), 9, 14, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        text.setSpan(ForegroundColorSpan(Color.BLUE), 9, 14, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        val tv = textView { setText(text, TextView.BufferType.SPANNABLE) }

        val regions = RegionProbe.probe(tv).regions
        assertEquals(1, regions.size, "the same run must not appear as both a span and a colour candidate")
        assertEquals(RegionSource.span, regions.single().source)
    }

    // --- Channel 4: structural markers ------------------------------------

    @Test
    fun bracketedPhrasesInASelfDrawnRowAreFlaggedAndMapped() {
        val tv = textView {
            text = "我已阅读并同意《服务协议》和《隐私政策》"
            isClickable = true
        }
        val result = RegionProbe.probe(tv)
        assertTrue(result.suspectedMultiRegion, "a bracketed clickable row should be flagged, not read as plain text")
        val markers = result.regions.filter { it.source == RegionSource.textMarker }
        assertEquals(listOf("《服务协议》", "《隐私政策》"), markers.map { it.label })
        assertTrue(markers.all { it.rects.first().width > 0 })
    }

    @Test
    fun markdownLinksCarryTheirTarget() {
        val tv = textView {
            text = "Read [Terms](https://e/t) and [Privacy](https://e/p)"
            isClickable = true
        }
        val markers = RegionProbe.probe(tv).regions.filter { it.source == RegionSource.textMarker }
        assertEquals(listOf("Terms", "Privacy"), markers.map { it.label })
        assertEquals(listOf("https://e/t", "https://e/p"), markers.map { it.target })
    }

    @Test
    fun plainProseIsNeverGuessedToBeMultiRegion() {
        // Detection is structural, never lexical: keying on words like "agree"
        // would make the probe locale-specific and flag ordinary sentences.
        val tv = textView {
            text = "By signing in you accept the User Agreement and Privacy Policy"
            isClickable = true
        }
        val result = RegionProbe.probe(tv)
        assertFalse(result.suspectedMultiRegion)
        assertTrue(result.regions.isEmpty())
        // …but the grid still makes either phrase targetable by substring.
        assertNotNull(result.charGrid)
    }

    @Test
    fun aNonClickableBracketedRowIsNotFlagged() {
        val tv = textView { text = "See 《Terms》 for details" }
        assertFalse(RegionProbe.probe(tv).suspectedMultiRegion)
    }

    // --- Char grid --------------------------------------------------------

    @Test
    fun theGridHasOneBoundaryPerCharacterPlusTheTrailingEdge() {
        val tv = textView { text = "Hello world" }
        val grid = assertNotNull(RegionProbe.probe(tv).charGrid)
        assertEquals("Hello world", grid.text)
        val line = grid.lines.single()
        assertEquals(0, line.start)
        // n characters -> n+1 boundaries; without the last one the final
        // character has no rect.
        assertEquals(line.end - line.start + 1, line.xOffsets.size)
        assertFalse(grid.approximate, "plain LTR text is exact, not a best effort")
    }

    @Test
    fun boundariesAdvanceLeftToRightAndIncludeThePaddingOffset() {
        val tv = textView {
            text = "Hello world"
            setPadding(24, 12, 0, 0)
        }
        val line = assertNotNull(RegionProbe.probe(tv).charGrid).lines.single()
        line.xOffsets.zipWithNext { a, b -> assertTrue(a <= b, "boundaries must not go backwards") }
        assertTrue(line.xOffsets.first() >= 24.0, "the grid must be offset by the view's padding")
        assertTrue(line.bottom > line.top)
    }

    @Test
    fun aSubstringRangeMapsToItsOwnRectRatherThanTheWholeRow() {
        val text = "Read the Terms carefully"
        val tv = textView { this.text = text }
        val grid = assertNotNull(RegionProbe.probe(tv).charGrid)
        val start = text.indexOf("Terms")
        val rect = grid.rangeRects(start, start + 5).single()

        assertTrue(rect.width > 0)
        assertTrue(rect.x > grid.lines.single().xOffsets.first(), "the phrase does not start at the row's left edge")
        assertTrue(rect.width < tv.width * 0.8, "a five-character rect should not span the row")
    }

    @Test
    fun wrappedTextYieldsContiguousLinesStackedDownTheScreen() {
        val tv = textView(width = 220) {
            text = "The quick brown fox jumps over the lazy dog near the river bank"
        }
        val lines = assertNotNull(RegionProbe.probe(tv).charGrid).lines
        assertTrue(lines.size > 1, "this text must wrap at this width")
        lines.zipWithNext { a, b ->
            assertEquals(a.end, b.start, "line ranges must tile the text with no gap or overlap")
            assertTrue(b.top > a.top, "later lines must sit lower on screen")
        }
    }

    @Test
    fun aLinkEndingAtASoftWrapDoesNotSpillIntoAFullWidthRect() {
        // `getPrimaryHorizontal` returns the NEXT line's left edge for an offset
        // sitting exactly on a soft break, which used to collapse a wrapped link
        // into a bogus full-width rect — measured on a real three-link row.
        val text = SpannableString("Please accept the Terms of Service Agreement and continue to the next step")
        val start = text.indexOf("Terms of Service Agreement")
        text.setSpan(URLSpan("https://e/t"), start, start + "Terms of Service Agreement".length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        val tv = textView(width = 220) { setText(text, TextView.BufferType.SPANNABLE) }

        val region = RegionProbe.probe(tv).regions.single { it.source == RegionSource.span }
        assertTrue(region.rects.size >= 2, "a wrapped link should report one rect per line")
        for (rect in region.rects) {
            assertTrue(rect.width > 0)
            assertTrue(rect.width <= tv.width.toDouble() + 1, "a line rect wider than the view means a wrap boundary leaked")
        }
    }

    @Test
    fun emptyAndNonTextViewsProduceNothingRatherThanAnEmptyGrid() {
        assertNull(RegionProbe.probe(textView { text = "" }).charGrid)
        val group = LinearLayout(context)
        val result = RegionProbe.probe(group)
        assertTrue(result.regions.isEmpty())
        assertNull(result.charGrid)
        assertFalse(result.suspectedMultiRegion)
    }
}
