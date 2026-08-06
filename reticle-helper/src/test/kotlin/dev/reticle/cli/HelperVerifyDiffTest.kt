package dev.reticle.cli

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * What `act --verify` compares. The measured gap: a tap on an `unchecked`
 * select-all consent button reported exactly one change — the DOM node's css path,
 * because that page happens to add an `active` class — and nothing said the box was
 * now ticked. A native checkbox, or a page that styles its own state without a
 * class change, would have reported "this node's watched fields are unchanged" for
 * the one field that did change.
 */
class HelperVerifyDiffTest {

    private fun state(
        checked: String? = null,
        expanded: String? = null,
        text: String? = null,
    ) = HelperVerify.VerifyState(
        found = true,
        text = text,
        label = null,
        enabled = true,
        visible = true,
        frame = "0,0 100x50",
        checked = checked,
        expanded = expanded,
        custom = emptyMap(),
    )

    @Test
    fun tickingABoxIsAChange() {
        val changes = HelperVerify.diff(state(checked = "off"), state(checked = "on"))
        assertEquals("off" to "on", changes["checked"])
    }

    @Test
    fun aBoxThatWasNeverCheckableReportsNothingAboutIt() {
        // Absence is the third state — a node with no toggle channel must not read
        // as one that stayed unticked.
        assertTrue(HelperVerify.diff(state(), state()).isEmpty())
    }

    @Test
    fun openingADropdownIsAChange() {
        val changes = HelperVerify.diff(state(expanded = "false"), state(expanded = "true"))
        assertEquals("false" to "true", changes["expanded"])
    }

    @Test
    fun theOtherWatchedFieldsStillCount() {
        val changes = HelperVerify.diff(state(text = "3414"), state(text = "6072"))
        assertEquals("3414" to "6072", changes["text"])
    }
}
