package dev.reticle.agent

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The Compose semantics reader, against a stand-in tree.
 *
 * `SemanticsReflect` is the whole of Reticle's access to Compose: every
 * `composeSemantics` node, its selector, its text, its toggle state and its scroll
 * capability come through here. It also carries the rule the architecture is built
 * on — Compose elements are targets ONLY through the semantics tree, never through
 * private internals — so what it reads by name is a contract, not an implementation
 * detail.
 *
 * It needs no Robolectric: the reader touches no Android type. What it does touch
 * is a set of Compose property NAMES, and those are what these tests pin, next to
 * the three pieces of logic that are not a straight read — the scroll-range
 * arithmetic (including `reverseScrolling`, which flips which end "up" is), the
 * two independent keys that can carry a toggle, and label-vs-value.
 *
 * `scenario.compose` in `scripts/e2e-android.sh` remains the proof that Compose
 * still spells things this way. That suite is manual and device-bound; this one
 * runs on every push.
 */
class SemanticsReflectTest {

    private fun node(vararg properties: Pair<String, Any>) = FakeSemanticsNode(properties.toMap())

    @Test
    fun readsTheSelectorAndLabelProperties() {
        val n = node(
            "TestTag" to "checkout.payButton",
            "ContentDescription" to listOf("Pay now"),
            "Role" to "Button",
        )

        assertEquals("checkout.payButton", SemanticsReflect.testTag(n))
        assertEquals("Pay now", SemanticsReflect.contentDescription(n))
        assertEquals("Button", SemanticsReflect.role(n))
    }

    @Test
    fun aFieldsLabelAndItsValueAreDifferentFacts() {
        // On a Material `TextField`, `Text` is the LABEL and `EditableText` is what
        // the user typed. Reading only `Text` made a Compose field's value invisible:
        // `act type` reported chars=6 with no channel that could check six arrived.
        val field = node(
            "Text" to listOf("Verification code"),
            "EditableText" to "123456",
        )

        assertEquals("Verification code", SemanticsReflect.text(field))
        assertEquals("123456", SemanticsReflect.editableText(field))
    }

    @Test
    fun textJoinsTheListComposeActuallyStores() {
        // SemanticsProperties.Text is a List<AnnotatedString>, not a String.
        assertEquals("Terms and Conditions", SemanticsReflect.text(node("Text" to listOf("Terms and", "Conditions"))))
        assertNull(SemanticsReflect.text(node()))
    }

    @Test
    fun theAnnotatedStringSurvivesUnflattened() {
        // `annotatedText` keeps the object so its link annotations reach
        // `ComposeTextRegions`; flattening it there would lose the links inside one
        // `Text`, which is the whole of the Compose agreement-row path.
        val annotated = StringBuilder("Terms")
        assertTrue(SemanticsReflect.annotatedText(node("Text" to listOf(annotated))) === annotated)
    }

    @Test
    fun aClickActionIsPresenceNotValue() {
        assertTrue(SemanticsReflect.hasClickAction(node("OnClick" to Any())))
        assertFalse(SemanticsReflect.hasClickAction(node("Text" to listOf("nope"))))
    }

    // MARK: - Toggle state: two keys, one answer

    @Test
    fun aTriStateToggleMapsToTheProtocolsOwnSpelling() {
        assertEquals("on", SemanticsReflect.checkedState(node("ToggleableState" to FakeToggle.On)))
        assertEquals("off", SemanticsReflect.checkedState(node("ToggleableState" to FakeToggle.Off)))
        assertEquals("mixed", SemanticsReflect.checkedState(node("ToggleableState" to FakeToggle.Indeterminate)))
    }

    @Test
    fun aRadioButtonCarriesTheSameFactUnderADifferentKey() {
        // A Checkbox/Switch sets `ToggleableState`; a RadioButton/selectable row sets
        // `Selected`. A reader that knew only one reported the other as stateless.
        assertEquals("on", SemanticsReflect.checkedState(node("Selected" to true)))
        assertEquals("off", SemanticsReflect.checkedState(node("Selected" to false)))
        assertNull(SemanticsReflect.checkedState(node("Text" to listOf("plain"))))
    }

    @Test
    fun anUnknownToggleSpellingIsNullRatherThanAGuess() {
        assertNull(SemanticsReflect.checkedState(node("ToggleableState" to "PartiallyOn")))
    }

    // MARK: - Scroll ranges

    @Test
    fun aContainerAtTheStartCanOnlyScrollForward() {
        val info = SemanticsReflect.scrollInfo(node("VerticalScrollAxisRange" to FakeScrollAxisRange(0f, 500f)))

        assertNotNull(info)
        assertFalse(info.canScrollUp)
        assertTrue(info.canScrollDown)
    }

    @Test
    fun aContainerAtTheEndCanOnlyScrollBack() {
        val info = SemanticsReflect.scrollInfo(node("VerticalScrollAxisRange" to FakeScrollAxisRange(500f, 500f)))

        assertNotNull(info)
        assertTrue(info.canScrollUp)
        assertFalse(info.canScrollDown)
    }

    @Test
    fun reverseScrollingFlipsWhichEndIsWhich() {
        // A reversed list (a chat transcript) sits at value 0 while being at the
        // BOTTOM. Ignoring the flag reports `scroll:down` for a container that
        // cannot, which is what `act wait` reads as "the row may simply be unbound"
        // — an `unknowable` where the honest answer is `absent`.
        val info = SemanticsReflect.scrollInfo(
            node("VerticalScrollAxisRange" to FakeScrollAxisRange(0f, 500f, reverseScrolling = true))
        )

        assertNotNull(info)
        assertTrue(info.canScrollUp)
        assertFalse(info.canScrollDown)
    }

    @Test
    fun aHorizontalRangeIsReadOnItsOwnAxis() {
        val info = SemanticsReflect.scrollInfo(
            node("HorizontalScrollAxisRange" to FakeScrollAxisRange(10f, 500f))
        )

        assertNotNull(info)
        assertTrue(info.canScrollLeft)
        assertTrue(info.canScrollRight)
        assertFalse(info.canScrollUp)
        assertFalse(info.canScrollDown)
    }

    @Test
    fun aContainerThatCannotMoveReportsNoScrollAtAll() {
        // Nothing to say is said as nothing: a `scroll:` marker on an unscrollable
        // container is exactly the false "may simply be unbound" hint above.
        assertNull(SemanticsReflect.scrollInfo(node("VerticalScrollAxisRange" to FakeScrollAxisRange(0f, 0f))))
        assertNull(SemanticsReflect.scrollInfo(node("Text" to listOf("plain"))))
    }

    // MARK: - Geometry and traversal

    @Test
    fun boundsComeBackAsAnOriginAndASize() {
        // Compose gives left/top/right/bottom; the protocol's Rect is x/y/w/h, and
        // getting that conversion wrong is a rect that is plausible and wrong.
        val rect = SemanticsReflect.boundsInWindow(
            FakeSemanticsNode(emptyMap(), bounds = FakeComposeRect(10f, 20f, 110f, 70f))
        )

        assertNotNull(rect)
        assertEquals(10.0, rect.x)
        assertEquals(20.0, rect.y)
        assertEquals(100.0, rect.width)
        assertEquals(50.0, rect.height)
    }

    @Test
    fun childrenComeBackInOrderAndAnEmptyTreeIsNotAnError() {
        val leaf = node("TestTag" to "leaf")
        val root = FakeSemanticsNode(emptyMap(), children = listOf(leaf))

        assertEquals(1, SemanticsReflect.children(root).size)
        assertTrue(SemanticsReflect.children(leaf).isEmpty())
    }

    @Test
    fun aShapeThatDoesNotMatchDegradesToNullRatherThanThrowing() {
        // The failure mode this whole file is written against: a future Compose that
        // renames or restructures a property must cost a missing fact, not a crash
        // inside the app under test's own capture.
        val alien = "not a semantics node at all"

        assertTrue(SemanticsReflect.children(alien).isEmpty())
        assertNull(SemanticsReflect.testTag(alien))
        assertNull(SemanticsReflect.boundsInWindow(alien))
        assertNull(SemanticsReflect.scrollInfo(alien))
        assertNull(SemanticsReflect.checkedState(alien))
        assertNull(SemanticsReflect.textLayoutResult(alien))
        assertFalse(SemanticsReflect.hasClickAction(alien))
    }
}

/** Compose's `ToggleableState` is an enum read by CONSTANT NAME, never by type. */
enum class FakeToggle { On, Off, Indeterminate }
