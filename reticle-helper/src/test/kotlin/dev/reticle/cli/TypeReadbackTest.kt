package dev.reticle.cli

import dev.reticle.core.MetadataValue
import dev.reticle.core.Node
import dev.reticle.core.NodeKind
import dev.reticle.core.Rect
import dev.reticle.core.ScreenInfo
import dev.reticle.core.Size
import dev.reticle.core.Snapshot
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * [TypeReadback]: what actually reached the field, against what `chars=N` says was
 * sent. The measured failure this pins is `--text "10000"` reported as `chars=5`
 * into a field that held `100` — a `TextWatcher` that reformats and re-lays-out on
 * every change eating characters out of the `adb input text` burst, while the
 * neighbouring field on the same screen took all five.
 */
class TypeReadbackTest {

    @Test
    fun everythingSentIsInTheFieldIsExact() {
        val verdict = TypeReadback.classify(before = "", after = "10000", typed = "10000")
        assertEquals(TypeReadback.Landed.EXACT, verdict.landed)
        assertEquals(5, verdict.landedChars)
        assertFalse(TypeReadback.isLoss(verdict.landed))
    }

    @Test
    fun theMeasuredFailure_threeOfFiveCharactersIsPartial() {
        val verdict = TypeReadback.classify(before = "", after = "100", typed = "10000")
        assertEquals(TypeReadback.Landed.PARTIAL, verdict.landed)
        assertEquals(3, verdict.landedChars)
        assertTrue(TypeReadback.isLoss(verdict.landed))
    }

    @Test
    fun anUnchangedFieldIsNone() {
        // The whole burst went nowhere — a different failure from a partial one,
        // and the only other one worth re-sending over the clipboard.
        val verdict = TypeReadback.classify(before = "", after = "", typed = "10000")
        assertEquals(TypeReadback.Landed.NONE, verdict.landed)
        assertTrue(TypeReadback.isLoss(verdict.landed))
    }

    @Test
    fun anAppsOwnFormattingIsNotALoss() {
        // Everything sent is there; the app added separators. Re-typing over this
        // would fight the app, so it is reported and left alone.
        val verdict = TypeReadback.classify(before = "", after = "10,000", typed = "10000")
        assertEquals(TypeReadback.Landed.REFORMATTED, verdict.landed)
        assertEquals(5, verdict.landedChars)
        assertFalse(TypeReadback.isLoss(verdict.landed))
    }

    @Test
    fun aTransformedValueIsChangedRatherThanPartial() {
        // Uppercasing, masking, a `maxLength` rewrite: the text is not what was
        // sent and is not a prefix of it either. Reticle reports it and does not
        // call the app wrong — this is the case that must never trigger a retry.
        val verdict = TypeReadback.classify(before = "", after = "ADA", typed = "ada")
        assertEquals(TypeReadback.Landed.CHANGED, verdict.landed)
        assertFalse(TypeReadback.isLoss(verdict.landed))
    }

    @Test
    fun insertionAtTheCursorIntoAFieldThatAlreadyHasTextIsExact() {
        // `type` inserts at the caret rather than replacing, so containment plus
        // the length delta — not equality — is what "all of it arrived" means.
        val verdict = TypeReadback.classify(before = "Ada", after = "AdaLovelace", typed = "Lovelace")
        assertEquals(TypeReadback.Landed.EXACT, verdict.landed)
    }

    @Test
    fun aPartialInsertionIntoANonEmptyFieldStillCounts() {
        val verdict = TypeReadback.classify(before = "Ada", after = "AdaLov", typed = "Lovelace")
        assertEquals(TypeReadback.Landed.PARTIAL, verdict.landed)
        assertEquals(3, verdict.landedChars)
    }

    @Test
    fun typingNothingLandsNothingAndIsNotAFailure() {
        assertEquals(TypeReadback.Landed.EXACT, TypeReadback.classify("x", "x", "").landed)
    }

    // -- picking and re-finding the field -------------------------------------

    private fun tree(
        focusedRef: String? = "r7",
        inputText: String? = "",
        inputRef: String = "r7",
        inputY: Double = 470.0,
    ): Snapshot {
        val nodes = LinkedHashMap<String, Node>()
        nodes["app"] = Node(ref = "app", kind = NodeKind.application, typeName = "Application", children = listOf("wrap"))
        nodes["wrap"] = Node(
            ref = "wrap", parentRef = "app", kind = NodeKind.view,
            typeName = "android.widget.LinearLayout", role = "container",
            testId = "form.amount", frame = Rect(0.0, 400.0, 1000.0, 200.0),
            isInteractive = true, children = listOf(inputRef),
        )
        nodes[inputRef] = Node(
            ref = inputRef, parentRef = "wrap", kind = NodeKind.view,
            typeName = "android.widget.EditText", role = "textField",
            resourceId = "etContent", text = inputText,
            frame = Rect(20.0, inputY, 960.0, 120.0),
            isInteractive = true, isFocusable = true, isFocused = focusedRef == inputRef,
        )
        return Snapshot(
            capturedAtMillis = 0L,
            screen = ScreenInfo(size = Size(1080.0, 2400.0), density = 3.0),
            rootRef = "app",
            nodes = nodes,
        )
    }

    @Test
    fun theFieldReadBackIsTheOneHoldingFocus() {
        // Focus is where `input text` delivers, whatever the caller named.
        assertEquals("r7", TypeReadback.field(tree(focusedRef = "r7"), targetRef = "wrap")?.ref)
    }

    @Test
    fun withNoFocusChannelItFallsBackToTheInputInsideTheTarget() {
        // Compose / DOM: the platform focus sits on the host view, whose text is
        // not the field's, so the target the caller named is the better answer.
        assertEquals("r7", TypeReadback.field(tree(focusedRef = null), targetRef = "wrap")?.ref)
    }

    @Test
    fun noTextFieldAnywhereReadsBackNothing() {
        val snapshot = Snapshot(
            capturedAtMillis = 0L,
            screen = ScreenInfo(size = Size(1080.0, 2400.0), density = 3.0),
            rootRef = "app",
            nodes = mapOf("app" to Node(ref = "app", kind = NodeKind.application, typeName = "Application")),
        )
        assertNull(TypeReadback.field(snapshot, targetRef = "app"))
    }

    @Test
    fun theFieldIsRefoundAfterATypingRelayoutRenumbersTheTree() {
        // Refs are traversal indices: the re-render that eats the characters is
        // also the one that can renumber the node they were typed into, so the
        // read-back matches on the node's own handles instead.
        val before = tree(inputRef = "r7")
        // Moved as well as renumbered — the relayout is the whole point, so the
        // match cannot lean on the rect either.
        val after = tree(inputRef = "r31", inputText = "100", focusedRef = "r31", inputY = 690.0)
        val found = TypeReadback.refind(after, before.nodes["r7"]!!)
        assertEquals("r31", found?.ref)
        assertEquals("100", found?.text)
    }

    @Test
    fun aFieldThatLeftTheTreeIsNotSubstituted() {
        val before = tree(inputRef = "r7")
        val empty = Snapshot(
            capturedAtMillis = 0L,
            screen = ScreenInfo(size = Size(1080.0, 2400.0), density = 3.0),
            rootRef = "app",
            nodes = mapOf("app" to Node(ref = "app", kind = NodeKind.application, typeName = "Application")),
        )
        assertNull(TypeReadback.refind(empty, before.nodes["r7"]!!))
    }

    /**
     * A web form used to be structurally unreadable: `isTextField` returned false
     * for every DOM node, so `type` into any web input reported
     * `textLanded=unreadable` no matter what happened — and the partial/none
     * recovery, which only fires on a classified loss, could never fire for a web
     * form at all. The reason given (`dom-input-value-not-separable-from-
     * placeholder`) was true while the bridge emitted `value || placeholder` as one
     * string; it does not any more, and neither does the wall.
     */
    private fun domTree(value: String? = null, role: String = "textField"): Snapshot {
        val nodes = LinkedHashMap<String, Node>()
        nodes["app"] = Node(ref = "app", kind = NodeKind.application, typeName = "Application", children = listOf("web"))
        nodes["web"] = Node(
            ref = "web", parentRef = "app", kind = NodeKind.view,
            typeName = "android.webkit.WebView", role = "container",
            frame = Rect(0.0, 200.0, 1080.0, 2000.0), isInteractive = true,
            // The host view owns the platform focus while the caret is in the DOM.
            isFocusable = true, isFocused = true, children = listOf("dom"),
        )
        nodes["dom"] = Node(
            ref = "dom", parentRef = "web", kind = NodeKind.domNode,
            typeName = "DOMElement", role = role, text = value,
            frame = Rect(40.0, 400.0, 900.0, 100.0), isInteractive = true,
            custom = mapOf("domPlaceholder" to MetadataValue.Text("Postcode")),
        )
        return Snapshot(
            capturedAtMillis = 0L,
            screen = ScreenInfo(size = Size(1080.0, 2400.0), density = 3.0),
            rootRef = "app",
            nodes = nodes,
        )
    }

    @Test
    fun aDomInputIsTheFieldToReadBack() {
        // The WebView holds the platform focus, so the focus-first lookup finds no
        // text field and the resolved target is the answer — as it is for Compose.
        assertEquals("dom", TypeReadback.field(domTree(), targetRef = "dom")?.ref)
    }

    @Test
    fun anEmptyDomInputIsEmptyNotUnreadable() {
        // The agents omit a blank value, so an empty input carries no `text` at all.
        // Reading that as "no text channel" turned the commonest state a field can
        // be in into a missing check — and one that looks like a wall, not a zero.
        val field = TypeReadback.field(domTree(value = null), targetRef = "dom")
        assertEquals("dom", field?.ref)
        // "" and null are different claims — "the field holds nothing" versus "there
        // is no text channel here" — and this case is the first. It used to come back
        // null, which is what this test's own name says it must not be: `--clear` on
        // an empty field then refused with `field-exposes-no-text`, reporting a
        // missing check where there was a passing one.
        assertEquals("", TypeReadback.valueOf(field!!))
        // ...and the placeholder is NOT what comes back as the value.
        assertEquals(
            TypeReadback.Landed.EXACT,
            TypeReadback.classify(before = "", after = "00-001", typed = "00-001").landed,
        )
    }

    /** A wrapper div with `count` inputs under it, one optionally focused. */
    private fun wrapperTree(count: Int, focusedIndex: Int? = null, value: String? = null): Snapshot {
        val nodes = LinkedHashMap<String, Node>()
        nodes["app"] = Node(ref = "app", kind = NodeKind.application, typeName = "Application", children = listOf("web"))
        nodes["web"] = Node(
            ref = "web", parentRef = "app", kind = NodeKind.view,
            typeName = "android.webkit.WebView", role = "container",
            frame = Rect(0.0, 200.0, 1080.0, 2000.0), isInteractive = true,
            isFocusable = true, isFocused = true, children = listOf("wrap"),
        )
        val inputs = (0 until count).map { "in$it" }
        nodes["wrap"] = Node(
            ref = "wrap", parentRef = "web", kind = NodeKind.domNode,
            typeName = "DOMElement", role = "div",
            frame = Rect(40.0, 380.0, 900.0, 200.0), children = inputs,
        )
        inputs.forEachIndexed { index, ref ->
            nodes[ref] = Node(
                ref = ref, parentRef = "wrap", kind = NodeKind.domNode,
                typeName = "DOMElement", role = "textField",
                text = if (index == focusedIndex) value else null,
                frame = Rect(40.0, 400.0 + index * 100.0, 900.0, 90.0),
                isInteractive = true, isFocused = index == focusedIndex,
            )
        }
        return Snapshot(
            capturedAtMillis = 0L,
            screen = ScreenInfo(size = Size(1080.0, 2400.0), density = 3.0),
            rootRef = "app",
            nodes = nodes,
        )
    }

    @Test
    fun aResolvedWrapperReadsBackTheInputInsideIt() {
        // Measured on a real form: a selector resolved the wrapper `<div>`, not the
        // `<input>`, and the read-back answered `unavailable:dom-node-is-not-a-text-
        // input` for text that plainly landed — `ui compact` showed the value in the
        // field at that same moment.
        val field = TypeReadback.field(wrapperTree(count = 1), targetRef = "wrap")
        assertEquals("in0", field?.ref)
    }

    @Test
    fun withSeveralInputsTheFocusedOneSettlesIt() {
        // Two inputs would be a guess — except that the caret is not a guess.
        val focused = TypeReadback.field(
            wrapperTree(count = 3, focusedIndex = 1, value = "abc"), targetRef = "wrap",
        )
        assertEquals("in1", focused?.ref)
        assertEquals("abc", TypeReadback.valueOf(focused!!))

        // With none focused, it stays a guess and is refused — but the message names
        // the wrapper AND the count, instead of claiming the node is not an input.
        val ambiguous = wrapperTree(count = 3)
        assertNull(TypeReadback.field(ambiguous, targetRef = "wrap"))
        val why = TypeReadback.whyUnreadable(ambiguous, targetRef = "wrap")
        assertContains(why, "wrap is a wrapper around 3 text inputs")
    }

    @Test
    fun anUnreadableResolvedNodeNamesWhereTheCaretIs() {
        // The other half of the confusion: the read looked at one node while the
        // caret was in another, and said neither.
        val snapshot = domTree(role = "button").let { tree ->
            val nodes = LinkedHashMap(tree.nodes)
            nodes["other"] = Node(
                ref = "other", parentRef = "web", kind = NodeKind.domNode,
                typeName = "DOMElement", role = "textField", text = "landed",
                frame = Rect(40.0, 600.0, 900.0, 90.0), isInteractive = true, isFocused = true,
            )
            nodes["web"] = nodes["web"]!!.copy(children = listOf("dom", "other"))
            tree.copy(nodes = nodes)
        }
        val why = TypeReadback.whyUnreadable(snapshot, targetRef = "dom")
        assertContains(why, "(dom)")
        assertContains(why, "the caret is in other")
    }

    @Test
    fun aDomElementThatIsNotATextInputSaysSoPrecisely() {
        // A button or a wrapper div is not "no text field on screen" — it is this
        // node not being an input, which is a different thing to tell the caller.
        val snapshot = domTree(role = "button")
        assertNull(TypeReadback.field(snapshot, targetRef = "dom"))
        assertEquals(
            TypeReadback.Unavailable.DOM_NOT_INPUT,
            TypeReadback.whyUnreadable(snapshot, targetRef = "dom"),
        )
    }

    @Test
    fun aMaskedFieldThatLostAMiddleCharacterIsDroppedNotChanged() {
        // Measured on a real masked postcode field: `--text "00-950"` left `00-50`.
        // The tail arrived, so it is not a PARTIAL prefix, and it used to classify
        // as CHANGED — a lost digit reported under the same label as an
        // uppercasing, and explicitly "never retried".
        val verdict = TypeReadback.classify(before = "", after = "00-50", typed = "00-950")
        assertEquals(TypeReadback.Landed.DROPPED, verdict.landed)
        assertEquals(4, verdict.landedChars)
        assertTrue(TypeReadback.isLoss(verdict.landed))
    }

    @Test
    fun anUppercasingAppIsStillChangedRatherThanDropped() {
        // The subsequence test is case-sensitive precisely so this stays CHANGED:
        // an app that rewrites its input has not lost any of it.
        val verdict = TypeReadback.classify(before = "", after = "ADA", typed = "ada")
        assertEquals(TypeReadback.Landed.CHANGED, verdict.landed)
        assertFalse(TypeReadback.isLoss(verdict.landed))
    }

    @Test
    fun aTransformedValueInAFIELDThatAlreadyHadTextStaysChanged() {
        // With pre-existing content the insertion point is unknown, so calling a
        // shorter value "dropped" would be a guess. CHANGED claims nothing.
        val verdict = TypeReadback.classify(before = "abc", after = "abX", typed = "de")
        assertEquals(TypeReadback.Landed.CHANGED, verdict.landed)
    }
}
