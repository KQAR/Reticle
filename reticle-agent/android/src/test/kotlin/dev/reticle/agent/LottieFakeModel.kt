package dev.reticle.agent

import android.graphics.PointF
import android.graphics.Rect

/**
 * A stand-in for Lottie's parsed composition, spelled the way `LottieBridge`
 * reads it.
 *
 * These are top-level PUBLIC classes on purpose. The bridge's `invoke` helper is
 * `getMethod(...).invoke(...)` with no `setAccessible`, exactly as it must be for
 * a library it does not link — so a method on a private nested class would throw
 * `IllegalAccessException`, the bridge would swallow it, and the suite would
 * "pass" against zero regions. A test that cannot fail is worse than no test.
 *
 * Names here mirror Lottie's own (`getLayerType`, `getKeyframes`, `startValue`,
 * `boxPosition`), because those names ARE the contract under test: change a
 * lookup in the bridge and these stop matching.
 */
enum class FakeLayerType { TEXT, SHAPE, IMAGE }

enum class FakeJustification { LEFT_JUSTIFY, CENTER, RIGHT_JUSTIFY }

/** Lottie reads a keyframe's value off the `startValue` FIELD, not a getter. */
class FakeKeyframe(@JvmField val startValue: Any?)

class FakeAnimatable(private val frames: List<FakeKeyframe>) {
    fun getKeyframes(): List<FakeKeyframe> = frames
}

class FakeTextDocument(
    @JvmField val text: String,
    @JvmField val size: Float,
    @JvmField val justification: FakeJustification,
    @JvmField val boxPosition: PointF?,
    @JvmField val boxSize: PointF?,
)

class FakeTransform(position: PointF, anchor: PointF) {
    private val positionValue = FakeAnimatable(listOf(FakeKeyframe(position)))
    private val anchorValue = FakeAnimatable(listOf(FakeKeyframe(anchor)))

    fun getPosition(): FakeAnimatable = positionValue
    fun getAnchorPoint(): FakeAnimatable = anchorValue
}

class FakeLayer(
    private val type: FakeLayerType,
    private val text: FakeAnimatable?,
    private val transform: FakeTransform,
) {
    fun getLayerType(): FakeLayerType = type
    fun getText(): FakeAnimatable? = text
    fun getTransform(): FakeTransform = transform
}

class FakeComposition(
    private val width: Int,
    private val height: Int,
    private val layers: List<Any?>,
) {
    fun getBounds(): Rect = Rect(0, 0, width, height)
    fun getLayers(): List<Any?> = layers
}

/** A TEXT layer at `position`, with an authored text box unless one is refused. */
fun fakeTextLayer(
    text: String,
    position: PointF,
    anchor: PointF = PointF(0f, 0f),
    size: Float = 12f,
    justification: FakeJustification = FakeJustification.LEFT_JUSTIFY,
    boxPosition: PointF? = PointF(0f, 0f),
    boxSize: PointF? = PointF(100f, 20f),
): FakeLayer = FakeLayer(
    type = FakeLayerType.TEXT,
    text = FakeAnimatable(
        listOf(FakeKeyframe(FakeTextDocument(text, size, justification, boxPosition, boxSize)))
    ),
    transform = FakeTransform(position, anchor),
)
