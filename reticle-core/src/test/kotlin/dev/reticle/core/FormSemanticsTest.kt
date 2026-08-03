package dev.reticle.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The three form facts the projection could not previously express, each measured
 * on a real onboarding flow before it had a test.
 *
 * 1. **Toggle state.** A consent row came back as `role: checkbox` with no state
 *    anywhere on the node, so the only way to read whether a tap had ticked it was
 *    a screenshot. The third state matters as much as the other two: "there is no
 *    checkbox here" and "there is a checkbox and it is unticked" lead to opposite
 *    next actions, which a `Boolean` defaulting to false collapses into the second.
 * 2. **Placeholder.** It used to be folded into the node's text as a fallback, so
 *    an empty field and a filled one projected identically — and `act type`'s
 *    read-back was structurally unable to say whether text had landed
 *    (`dom-input-value-not-separable-from-placeholder`).
 * 3. **Invalidity.** An error string sat in the tree as an ordinary sibling with
 *    nothing tying it to the field it was about.
 */
class FormSemanticsTest {

    private fun snapshot(vararg nodes: Node): Snapshot = Snapshot(
        capturedAtMillis = 0L,
        screen = ScreenInfo(size = Size(1080.0, 2400.0), density = 3.0),
        rootRef = "root",
        nodes = (
            listOf(
                Node(
                    ref = "root", kind = NodeKind.application, typeName = "Application",
                    children = nodes.map { it.ref },
                )
            ) + nodes
            ).associateBy { it.ref },
    )

    private fun field(
        ref: String,
        role: String = "textField",
        label: String? = null,
        checked: CheckedState? = null,
        custom: Map<String, MetadataValue> = emptyMap(),
    ) = Node(
        ref = ref, parentRef = "root", kind = NodeKind.domNode, typeName = "DOMElement",
        role = role, contentDescription = label, frame = Rect(60.0, 400.0, 960.0, 120.0),
        isInteractive = true, checked = checked, custom = custom,
    )

    private fun lineFor(ref: String, snapshot: Snapshot): String =
        CompactObservation.from(snapshot).items.first { it.ref == ref }.line()

    @Test
    fun aTickedBoxAnUntickedBoxAndNoBoxAtAllAreThreeDifferentReadings() {
        val snap = snapshot(
            field("on", role = "checkbox", label = "Accept the terms", checked = CheckedState.on),
            field("off", role = "checkbox", label = "Marketing email", checked = CheckedState.off),
            field("mixed", role = "checkbox", label = "Select all", checked = CheckedState.mixed),
            field("plain", label = "Not a checkbox"),
        )

        assertTrue(lineFor("on", snap).contains(" checked"), "a ticked box must say so")
        assertTrue(lineFor("off", snap).contains(" unchecked"), "an unticked box must say so")
        assertTrue(lineFor("mixed", snap).contains(" checked:mixed"), "a tri-state must keep its third value")
        // The one that matters most: a node that is not checkable says NOTHING,
        // rather than borrowing `unchecked` and reading like an untouched control.
        val plain = lineFor("plain", snap)
        assertTrue(!plain.contains("checked"), "a non-checkable node must not claim a toggle state: $plain")
        assertNull(
            CompactObservation.from(snap).items.first { it.ref == "plain" }.checked,
            "absence is the third state and must survive the projection",
        )
    }

    @Test
    fun aPlaceholderIsWhatTheFieldAsksForNotWhatItHolds() {
        val snap = snapshot(
            field("empty", custom = mapOf("domPlaceholder" to MetadataValue.Text("Email"))),
            Node(
                ref = "filled", parentRef = "root", kind = NodeKind.domNode, typeName = "DOMElement",
                role = "textField", text = "ada@example.com", frame = Rect(60.0, 600.0, 960.0, 120.0),
                isInteractive = true,
                custom = mapOf("domPlaceholder" to MetadataValue.Text("Email")),
            ),
        )

        val empty = lineFor("empty", snap)
        val filled = lineFor("filled", snap)
        assertTrue(empty.contains("placeholder:\"Email\""), "an empty field must still name what it wants: $empty")
        assertTrue(!empty.contains("\"Email\" ["), "the placeholder must not stand in as the value: $empty")
        assertTrue(filled.contains("\"ada@example.com\""), "a filled field reports its value: $filled")
        assertTrue(filled.contains("placeholder:\"Email\""), "and keeps the placeholder beside it: $filled")
        // The whole point: the two lines must be distinguishable.
        assertTrue(empty != filled, "an empty and a filled field must not project identically")
    }

    @Test
    fun anInvalidFieldCarriesItsOwnMessage() {
        val snap = snapshot(
            field(
                "named",
                custom = mapOf(
                    "domInvalid" to MetadataValue.Bool(true),
                    "domDescribedBy" to MetadataValue.Text("Enter a valid postcode"),
                ),
            ),
            field("unnamed", custom = mapOf("domInvalid" to MetadataValue.Bool(true))),
            field("valid"),
        )

        assertTrue(
            lineFor("named", snap).contains("invalid:\"Enter a valid postcode\""),
            "the message must travel with the field it belongs to",
        )
        // Invalid with no stated reason is still a different reading from valid —
        // only the second means there is nothing to fix.
        assertTrue(lineFor("unnamed", snap).contains(" invalid"), "invalidity is reported even unexplained")
        assertTrue(!lineFor("unnamed", snap).contains("invalid:"), "and does not invent a message")
        assertTrue(!lineFor("valid", snap).contains("invalid"), "a valid field says nothing")
        assertEquals(null, snap.node("valid")!!.domInvalidMessage())
    }

    @Test
    fun theStateSurvivesTheWire() {
        val snap = snapshot(
            field("box", role = "checkbox", label = "Accept", checked = CheckedState.off),
            field(
                "field",
                custom = mapOf(
                    "domPlaceholder" to MetadataValue.Text("Email"),
                    "domInvalid" to MetadataValue.Bool(true),
                    "domDescribedBy" to MetadataValue.Text("Required"),
                ),
            ),
        )
        val roundTripped = ReticleJson.compact.decodeFromString(
            Snapshot.serializer(),
            ReticleJson.compact.encodeToString(Snapshot.serializer(), snap),
        )

        assertEquals(CheckedState.off, roundTripped.node("box")!!.checked)
        assertEquals("Email", roundTripped.node("field")!!.domPlaceholder())
        assertEquals("Required", roundTripped.node("field")!!.domInvalidMessage())
        // Omit-defaults: a node with no toggle state must not gain one on the wire.
        assertNull(roundTripped.node("field")!!.checked)
    }
}
