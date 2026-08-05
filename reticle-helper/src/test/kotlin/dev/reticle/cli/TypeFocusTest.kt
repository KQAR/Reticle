package dev.reticle.cli

import dev.reticle.core.Node
import dev.reticle.core.NodeKind
import dev.reticle.core.Rect
import dev.reticle.core.ScreenInfo
import dev.reticle.core.Size
import dev.reticle.core.Snapshot
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * [TypeFocus]: after `act type` taps the field it was aimed at, who actually holds
 * focus. The measured failure this pins is a `type` that reported `chars=4` into a
 * field that stayed empty, because the resolved node was the compound widget's
 * outer container and the tap moved no focus into the `EditText` inside it.
 */
class TypeFocusTest {

    // A form row: a clickable wrapper (the only unique id) around a generic input.
    private fun form(
        focusedRef: String? = null,
        secondInput: Boolean = false,
    ): Snapshot {
        val nodes = LinkedHashMap<String, Node>()
        nodes["app"] = Node(ref = "app", kind = NodeKind.application, typeName = "Application", children = listOf("wrap", "other"))
        nodes["wrap"] = Node(
            ref = "wrap", parentRef = "app", kind = NodeKind.view,
            typeName = "android.widget.LinearLayout", role = "container",
            testId = "form.firstName", frame = Rect(0.0, 400.0, 1000.0, 200.0),
            isInteractive = true,
            // The false positive that makes this shape look fine: FOCUSABLE_AUTO
            // reports a clickable container as focusable. The capture records the
            // TOUCH reading instead, which is false here.
            isFocusable = false, isFocused = focusedRef == "wrap",
            children = buildList { add("label"); add("input"); if (secondInput) add("input2") },
        )
        nodes["label"] = Node(ref = "label", parentRef = "wrap", kind = NodeKind.view, typeName = "android.widget.TextView", role = "text", text = "First name")
        nodes["input"] = Node(
            ref = "input", parentRef = "wrap", kind = NodeKind.view,
            typeName = "android.widget.EditText", role = "textField",
            resourceId = "etContent", frame = Rect(20.0, 470.0, 960.0, 120.0),
            isInteractive = true, isFocusable = true, isFocused = focusedRef == "input",
        )
        if (secondInput) {
            nodes["input2"] = Node(
                ref = "input2", parentRef = "wrap", kind = NodeKind.view,
                typeName = "android.widget.EditText", role = "textField",
                resourceId = "etContent", frame = Rect(20.0, 600.0, 960.0, 120.0),
                isInteractive = true, isFocusable = true, isFocused = focusedRef == "input2",
            )
        }
        nodes["other"] = Node(
            ref = "other", parentRef = "app", kind = NodeKind.view,
            typeName = "android.widget.EditText", role = "textField",
            testId = "form.email", frame = Rect(20.0, 900.0, 960.0, 120.0),
            isInteractive = true, isFocusable = true, isFocused = focusedRef == "other",
        )
        return Snapshot(
            capturedAtMillis = 0L,
            screen = ScreenInfo(size = Size(1080.0, 2400.0), density = 3.0),
            rootRef = "app",
            nodes = nodes,
        )
    }

    @Test
    fun focusOnTheResolvedNodeIsSelf() {
        val snapshot = form(focusedRef = "other")
        assertEquals(TypeFocus.Landing.SELF, TypeFocus.classify(snapshot, "other"))
    }

    @Test
    fun focusInsideTheResolvedNodeIsADescendant() {
        // The compound widget working as intended: the wrapper was targeted and the
        // nested input took focus. Nothing to complain about.
        val snapshot = form(focusedRef = "input")
        assertEquals(TypeFocus.Landing.DESCENDANT, TypeFocus.classify(snapshot, "wrap"))
    }

    @Test
    fun focusAboveTheResolvedNodeIsAnAncestor() {
        // The WebView / AndroidComposeView shape: the caret is in a DOM or Compose
        // input, and the platform focus sits on the HOST view above the node the
        // selector named. Not a failure — no finer channel exists there.
        val snapshot = form(focusedRef = "wrap")
        assertEquals(TypeFocus.Landing.ANCESTOR, TypeFocus.classify(snapshot, "input"))
        assertTrue(TypeFocus.isLanded(TypeFocus.Landing.ANCESTOR))
    }

    @Test
    fun theMeasuredFailure_wrapperTargetedAndNothingTookFocus() {
        val snapshot = form(focusedRef = null)
        val landing = TypeFocus.classify(snapshot, "wrap")
        assertEquals(TypeFocus.Landing.NONE, landing)
        assertFalse(TypeFocus.isLanded(landing))
    }

    @Test
    fun focusOnAnUnrelatedFieldIsElsewhere() {
        // The worse half of the same bug: the text lands in a DIFFERENT field
        // rather than nowhere, which no change count would distinguish.
        val snapshot = form(focusedRef = "other")
        val landing = TypeFocus.classify(snapshot, "wrap")
        assertEquals(TypeFocus.Landing.ELSEWHERE, landing)
        assertFalse(TypeFocus.isLanded(landing))
    }

    @Test
    fun aRefThatIsNotInThisCaptureIsNotAClaimAboutAnUnrelatedNode() {
        // Measured on a real hybrid form: the focusing tap scrolled the field into
        // view, the WebView re-rendered, and every ref was renumbered — so the ref
        // the selector had resolved to was absent from the capture the focus was
        // read from. That used to classify as ELSEWHERE, which asserts the text is
        // about to land in a DIFFERENT field. It was not: the named field held
        // focus, and the identical command succeeded on the next attempt.
        val snapshot = form(focusedRef = "input")
        val landing = TypeFocus.classify(snapshot, "r9999")
        assertEquals(TypeFocus.Landing.TARGET_GONE, landing)
        assertFalse(TypeFocus.isLanded(landing))
    }

    @Test
    fun theTargetGoneRefusalSaysWhyAndWhatToUseInstead() {
        val target = ResolvedInputTarget(dev.reticle.core.Point(500.0, 500.0), "dom:css", "r9999")
        val message = TypeFocus.refusal(TypeFocus.Landing.TARGET_GONE, target, null)
        assertTrue(message.contains("renumbered"), message)
        assertTrue(message.contains("--css"), message)
        assertFalse(message.contains("focus is on an unrelated node"), message)
    }

    @Test
    fun aRawPointCanStillTellNobodyHasFocus() {
        // With no target ref there is nothing to be related TO, but "the text will
        // go nowhere" is still knowable — and still worth refusing.
        assertEquals(TypeFocus.Landing.NONE, TypeFocus.classify(form(focusedRef = null), null))
        assertEquals(TypeFocus.Landing.UNKNOWN, TypeFocus.classify(form(focusedRef = "input"), null))
    }

    @Test
    fun unknownCountsAsLanded() {
        // No focus reading (runtime unreachable, older agent) must never turn a
        // working `type` into a failure — it is reported, not enforced.
        assertTrue(TypeFocus.isLanded(TypeFocus.Landing.UNKNOWN))
    }

    @Test
    fun retargetsToTheOneFocusableInputInsideTheWrapper() {
        val candidate = TypeFocus.soleFocusableInput(form(), "wrap")
        assertEquals("input", candidate?.ref)
    }

    @Test
    fun refusesToPickWhenTheWrapperHoldsTwoInputs() {
        // Two fields under one wrapper is a guess, and guessing which one the
        // caller meant is how text lands in the wrong box while looking fine.
        assertNull(TypeFocus.soleFocusableInput(form(secondInput = true), "wrap"))
    }

    @Test
    fun aNonFocusableDescendantIsNotACandidate() {
        // The label is inside the wrapper too; only a focusable text input counts.
        val candidate = TypeFocus.soleFocusableInput(form(), "wrap")
        assertEquals("textField", candidate?.role)
    }

    @Test
    fun refusalNamesTheCandidateAndTheHandleToUseInstead() {
        val snapshot = form()
        val target = ResolvedInputTarget(dev.reticle.core.Point(500.0, 500.0), "semantic:testId", "wrap")
        val message = TypeFocus.refusal(
            TypeFocus.Landing.NONE, target, TypeFocus.soleFocusableInput(snapshot, "wrap"),
        )
        assertTrue(message.contains("--resource-id etContent"), message)
        assertTrue(message.contains("refused"), message)
    }
}
