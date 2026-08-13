package dev.reticle.agent

import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.InsetDrawable
import android.graphics.drawable.RippleDrawable
import android.view.View
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The reflection substrate every other reflective reader stands on.
 *
 * `ReticleReflect` is what `ComposeTextStyle`, `ComposeTextRegions` and the style
 * channel all reach through, and it had no unit test — so the whole reflective
 * half of the Android agent was guarded only by the manual, device-bound e2e.
 * These are the two behaviours that fail SILENTLY when they break, which is the
 * dangerous kind: a style property read as absent looks like a design that sets
 * nothing, and `styleGaps` (docs/boundaries.md's property-granular row) exists
 * precisely so that absence is never inferred.
 */
@RunWith(RobolectricTestRunner::class)
class ReticleReflectTest {

    private val context = RuntimeEnvironment.getApplication()

    private fun viewWith(background: android.graphics.drawable.Drawable?): View =
        View(context).apply { this.background = background }

    // MARK: - Value-class getters (the Compose path)

    @Test
    fun aMangledValueClassGetterIsFoundByPrefix() {
        val holder = MangledNameHolder()

        // The exact-name lookup cannot see it — which is why the prefix form exists.
        assertNull(ReticleReflect.invokeNoArg(holder, "getFontSize"))
        assertEquals(14L, ReticleReflect.invokeNoArgByPrefix(holder, "getFontSize"))
    }

    @Test
    fun anUnmangledGetterStillMatchesTheSamePrefixLookup() {
        // Compose mangles only SOME getters, and which ones changes between builds,
        // so the prefix form has to serve both or half the style silently vanishes.
        assertEquals("Inter", ReticleReflect.invokeNoArgByPrefix(MangledNameHolder(), "getFontFamily"))
    }

    @Test
    fun aPrefixDoesNotSwallowALongerPropertyName() {
        // `getFontSizeScale` shares the prefix as a string but is another property.
        // Matching it would report a scale factor as a font size — a plausible,
        // wrong number, which is worse than no number.
        val holder = MangledNameHolder()
        assertEquals(14L, ReticleReflect.invokeNoArgByPrefix(holder, "getFontSize"))
        assertEquals(2.0, ReticleReflect.invokeNoArgByPrefix(holder, "getFontSizeScale"))
    }

    @Test
    fun exactAndPrefixLookupsDoNotPoisonEachOthersCache() {
        // Both are memoised by (class, key) — `getFontSize` resolved to nothing by
        // exact name must not make the prefix lookup answer nothing too.
        val holder = MangledNameHolder()
        assertNull(ReticleReflect.invokeNoArg(holder, "getFontSize"))
        assertEquals(14L, ReticleReflect.invokeNoArgByPrefix(holder, "getFontSize"))
        assertNull(ReticleReflect.invokeNoArg(holder, "getFontSize"))
        assertEquals(14L, ReticleReflect.invokeNoArgByPrefix(holder, "getFontSize"))
    }

    @Test
    fun anAbsentMethodIsNullRatherThanAThrow() {
        // The agent reads these during capture, on the app's main thread. A shape
        // that does not match must cost a null, never an exception.
        assertNull(ReticleReflect.invokeNoArg(MangledNameHolder(), "getNothingLikeThis"))
        assertNull(ReticleReflect.invokeNoArgByPrefix(MangledNameHolder(), "getNothingLikeThis"))
    }

    // MARK: - Shape metrics (the style channel a View getter cannot answer)

    @Test
    fun aShapeBackgroundReportsItsCornerRadiusAndFill() {
        val background = GradientDrawable().apply {
            cornerRadius = 12f
            setColor(Color.RED)
        }

        val metrics = ReticleReflect.shapeMetrics(viewWith(background))

        assertEquals(12f, metrics.cornerRadiusPx)
        assertNull(metrics.cornerRadiusGap)
        assertEquals("#FFFF0000", metrics.fillColorHex)
    }

    @Test
    fun perCornerRadiiAreAGapRatherThanAnAbsence() {
        // Four different radii ARE a real shape; `getCornerRadius()` answers -1 for
        // it. Reporting no radius would read as "this design specifies none", which
        // is the exact inference docs/boundaries.md forbids — so it is a named gap.
        val background = GradientDrawable().apply {
            cornerRadii = floatArrayOf(8f, 8f, 0f, 0f, 8f, 8f, 0f, 0f)
        }

        val metrics = ReticleReflect.shapeMetrics(viewWith(background))

        assertNull(metrics.cornerRadiusPx)
        assertEquals("gradient-drawable-per-corner-radii", metrics.cornerRadiusGap)
    }

    @Test
    fun anInsetWrapperIsPeeledDownToTheShapeThatCarriesTheStyle() {
        // A Material component's real background usually sits a layer or two down;
        // reading the wrapper reports a styleless view.
        val shape = GradientDrawable().apply { cornerRadius = 6f }
        val metrics = ReticleReflect.shapeMetrics(viewWith(InsetDrawable(shape, 4)))

        assertEquals(6f, metrics.cornerRadiusPx)
    }

    @Test
    fun aRippleWrapperIsPeeledToo() {
        val shape = GradientDrawable().apply { cornerRadius = 10f }
        val ripple = RippleDrawable(ColorStateList.valueOf(Color.GRAY), shape, null)

        assertEquals(10f, ReticleReflect.shapeMetrics(viewWith(ripple)).cornerRadiusPx)
    }

    @Test
    fun aViewWithNoBackgroundReportsNothingAtAll() {
        assertTrue(ReticleReflect.shapeMetrics(viewWith(null)).isEmpty)
    }

    @Test
    fun aFlatColourBackgroundReportsItsFillAndNoShape() {
        // A ColorDrawable HAS a colour and has no shape — so the fill is reported and
        // the corner radius stays absent. Reporting 0 would be a claim ("square
        // corners") about a drawable that says nothing on the subject.
        val metrics = ReticleReflect.shapeMetrics(viewWith(ColorDrawable(Color.BLUE)))

        assertEquals("#FF0000FF", metrics.fillColorHex)
        assertNull(metrics.cornerRadiusPx)
        assertNull(metrics.cornerRadiusGap)
        assertNull(metrics.strokeWidthPx)
    }

    @Test
    fun aFlatColourBackgroundIsStillReadAsAColour() {
        // `backgroundColorHex` is the separate, simpler channel — a ColorDrawable
        // has no shape but does have the one property most screens set.
        assertEquals("#FF0000FF", ReticleReflect.backgroundColorHex(viewWith(ColorDrawable(Color.BLUE))))
        assertNull(ReticleReflect.backgroundColorHex(viewWith(GradientDrawable())))
    }

    // MARK: - Stable ids

    @Test
    fun aKeylessStringTagIsATestTagAndABlankOneIsNot() {
        assertEquals("checkout.payButton", ReticleReflect.testTag(View(context).apply { tag = "checkout.payButton" }))
        assertNull(ReticleReflect.testTag(View(context).apply { tag = "  " }))
        assertNull(ReticleReflect.testTag(View(context).apply { tag = 42 }))
    }

    @Test
    fun reactNativesNativeIdIsAbsentWhenReactNativeIsNot() {
        // The R.id constant lives in RN's own resources, so 0 means "not this app".
        // The read must degrade to null rather than to an exception on the id lookup.
        assertNull(ReticleReflect.nativeId(View(context)))
    }

    @Test
    fun aResourceIdIsReportedByItsEntryNameOnly() {
        val view = View(context).apply { id = android.R.id.content }

        val name = ReticleReflect.resourceEntryName(view)

        assertNotNull(name)
        assertEquals("content", name)
        assertNull(ReticleReflect.resourceEntryName(View(context)), "NO_ID has no entry name")
    }
}
