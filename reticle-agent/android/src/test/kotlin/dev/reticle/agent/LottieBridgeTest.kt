package dev.reticle.agent

import android.graphics.PointF
import android.view.View
import android.widget.ImageView
import com.airbnb.lottie.LottieAnimationView
import dev.reticle.core.Rect
import dev.reticle.core.RegionSource
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Text layers recovered from inside a Lottie.
 *
 * This is the Android twin of `LottieBridgeTests` on iOS, and it exists for the
 * same reason: the bridge is pure reflection into a library the agent does not
 * link, so the code has no compiler holding it to anything. `scenario.lottieOnlyDialog`
 * in `scripts/e2e-android.sh` proves the reflection matches a real Lottie build —
 * but that suite is manual, needs a device, and is not in CI, so until now the
 * whole path had no automated guard at all.
 *
 * What is pinned here is the half an e2e cannot isolate: the composition→screen
 * arithmetic (where a mishandled content mode yields a plausible-but-WRONG rect —
 * the worst outcome, since a wrong rect taps something) and every refusal path.
 * Robolectric runs in NATIVE graphics mode (`src/test/resources/robolectric.properties`),
 * so `Paint.measureText` is real measurement rather than a stub — which matters,
 * because the glyph extent is what the rect is built from.
 */
@RunWith(RobolectricTestRunner::class)
class LottieBridgeTest {

    private val context = RuntimeEnvironment.getApplication()

    private fun lottieView(
        composition: Any?,
        scaleType: ImageView.ScaleType = ImageView.ScaleType.FIT_CENTER,
    ): LottieAnimationView = LottieAnimationView(context).apply {
        this.scaleType = scaleType
        this.composition = composition
    }

    private fun frame(x: Double, y: Double, w: Double, h: Double) = Rect(x, y, w, h)

    @Test
    fun aTextLayerBecomesALottieRegionCarryingItsOwnText() {
        val view = lottieView(
            FakeComposition(100, 100, listOf(fakeTextLayer("Confirm", PointF(10f, 20f))))
        )

        val regions = LottieBridge.regionsFor(view, frame(0.0, 0.0, 100.0, 100.0))

        assertEquals(1, regions.size)
        assertEquals(RegionSource.lottie, regions[0].source)
        assertEquals("Confirm", regions[0].label)
        val rect = regions[0].rects.single()
        assertTrue(rect.width > 0 && rect.height > 0, "a measured glyph rect: $rect")
    }

    /**
     * The bug this catches: with `FIT_CENTER` (the LottieAnimationView default) a
     * composition narrower than its view is LETTERBOXED, so every layer's screen x
     * is shifted by half the slack. Ignore that and the rects are uniformly wrong
     * by a constant — plausible, self-consistent, and off the target.
     */
    @Test
    fun fitCenterLetterboxesInsteadOfStretching() {
        val layer = fakeTextLayer("Confirm", PointF(0f, 0f), boxPosition = null, boxSize = null)
        val square = lottieView(FakeComposition(100, 100, listOf(layer)))

        // A 300x100 view for a 100x100 composition: scale 1, 100px of slack a side.
        val wide = LottieBridge.regionsFor(square, frame(0.0, 0.0, 300.0, 100.0)).single()
        val exact = LottieBridge.regionsFor(square, frame(0.0, 0.0, 100.0, 100.0)).single()

        assertEquals(exact.rects.single().width, wide.rects.single().width, 0.01,
            "uniform scale is 1 in both, so the glyph is the same size")
        assertEquals(100.0, wide.rects.single().x - exact.rects.single().x, 0.01,
            "…and shifted by half the horizontal slack")
    }

    /** `FIT_XY` is the other branch: no letterbox, and the two axes scale apart. */
    @Test
    fun fitXyStretchesBothAxesIndependently() {
        val layer = fakeTextLayer("Confirm", PointF(50f, 50f), boxPosition = null, boxSize = null)
        val view = lottieView(FakeComposition(100, 100, listOf(layer)), ImageView.ScaleType.FIT_XY)

        val rect = LottieBridge.regionsFor(view, frame(0.0, 0.0, 200.0, 400.0)).single().rects.single()

        // Composition (50,50) maps to (50*2, 50*4) with no centering offset.
        assertEquals(100.0, rect.x, 0.01)
        assertTrue(rect.y > 150.0, "the y axis scaled by 4, independently of x: $rect")
    }

    /**
     * Justification is what decides whether the rect's CENTER — the point a
     * `act tap --region` uses — lands on the glyphs. A centred title placed as if
     * it were left-aligned reports a rect beside the text it names.
     */
    @Test
    fun centreJustifiedTextIsPlacedAroundTheBoxCentre() {
        val box = PointF(200f, 40f)
        val centred = fakeTextLayer(
            "Confirm", PointF(0f, 0f),
            justification = FakeJustification.CENTER, boxSize = box,
        )
        val left = fakeTextLayer(
            "Confirm", PointF(0f, 0f),
            justification = FakeJustification.LEFT_JUSTIFY, boxSize = box,
        )
        val view = lottieView(FakeComposition(400, 400, listOf(centred, left)))

        val rects = LottieBridge.regionsFor(view, frame(0.0, 0.0, 400.0, 400.0)).map { it.rects.single() }
        val centreOf = { r: Rect -> r.x + r.width / 2 }

        assertEquals(100.0, centreOf(rects[0]), 1.0, "centred: the box's own middle")
        assertTrue(centreOf(rects[1]) < centreOf(rects[0]),
            "left-justified starts at the box origin, so its centre sits earlier: $rects")
    }

    @Test
    fun aNonTextLayerContributesNothing() {
        val shape = FakeLayer(FakeLayerType.SHAPE, null, FakeTransform(PointF(0f, 0f), PointF(0f, 0f)))
        val view = lottieView(FakeComposition(100, 100, listOf(shape)))

        assertTrue(LottieBridge.regionsFor(view, frame(0.0, 0.0, 100.0, 100.0)).isEmpty())
    }

    @Test
    fun anEmptyTextLayerIsNotATarget() {
        // A blank string would produce a zero-width rect and a nameless region —
        // addressable, and pointing at nothing.
        val view = lottieView(FakeComposition(100, 100, listOf(fakeTextLayer("   ", PointF(0f, 0f)))))

        assertTrue(LottieBridge.regionsFor(view, frame(0.0, 0.0, 100.0, 100.0)).isEmpty())
    }

    /**
     * Every refusal in one place. The bridge's contract is that an absent class, a
     * renamed member or an unexpected shape yields NO regions rather than a crash —
     * it runs inside the app under test, on its main thread, during capture.
     */
    @Test
    fun everyMissingPieceDegradesToNoRegionsRatherThanThrowing() {
        val good = FakeComposition(100, 100, listOf(fakeTextLayer("Confirm", PointF(0f, 0f))))
        val screen = frame(0.0, 0.0, 100.0, 100.0)

        // Not a Lottie view at all: the class-name check is the gate.
        assertTrue(LottieBridge.regionsFor(View(context), screen).isEmpty())
        // A Lottie view whose animation has not loaded yet.
        assertTrue(LottieBridge.regionsFor(lottieView(null), screen).isEmpty())
        // No frame: nothing to map composition space onto.
        assertTrue(LottieBridge.regionsFor(lottieView(good), null).isEmpty())
        // A composition of zero size would divide by zero on the way to a scale.
        assertTrue(LottieBridge.regionsFor(lottieView(FakeComposition(0, 0, listOf())), screen).isEmpty())
        // A model that answers none of the lookups: the shape changed under us.
        assertTrue(LottieBridge.regionsFor(lottieView("not a composition"), screen).isEmpty())
    }
}
