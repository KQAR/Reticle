package dev.reticle.core

import dev.reticle.core.trace.ActionTraceChange
import dev.reticle.core.trace.ActionTraceDiff
import dev.reticle.core.trace.ActionTraceNodeIdentity
import dev.reticle.core.trace.ActionTraceParams
import kotlinx.serialization.Serializable
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.fail

/**
 * The action-trace diff contract, driven by the language-neutral fixture at
 * reticle-protocol/fixtures/action-trace-diff.cases.json.
 *
 * The Swift twin (`ActionTraceDiff` in reticle-host/Sources/ReticleHostIos)
 * reads the same file. Both are hand-written 1:1 ports, and this diff is what a
 * reader — often a small model with no budget to open a 100KB snapshot — uses to
 * decide whether an action landed. A rule changed on one side only would let the
 * two platforms describe the same action differently, which is the failure the
 * selector-resolution fixture was introduced to stop happening a second time.
 *
 * Order is asserted, not just membership: ranking decides what survives the cap,
 * so a diff with the right changes in the wrong order is a different contract.
 */
class ActionTraceDiffContractTest {

    @Serializable
    private data class Case(
        val name: String,
        val why: String = "",
        val maxChanges: Int = 100,
        val before: Snapshot,
        val after: Snapshot,
        val expect: List<ActionTraceChange>,
    )

    @Serializable
    private data class Cases(
        val cases: List<Case>,
        val recordedParams: List<String> = emptyList(),
    )

    private fun document(): Cases {
        val text = javaClass.classLoader
            .getResourceAsStream("fixtures/action-trace-diff.cases.json")
            ?.bufferedReader()?.readText()
            ?: fail("missing fixtures/action-trace-diff.cases.json on the test classpath")
        return ReticleJson.instance.decodeFromString(Cases.serializer(), text)
    }

    private fun cases(): List<Case> = document().cases

    /**
     * The recorded-param allow-list exists by hand in Kotlin and in Swift
     * (`ActionTraceParamNames.recorded`). A key added to one side only would make
     * the same gesture record differently on Android and iOS, and nothing in the
     * diff cases above would notice.
     */
    @Test
    fun recordedParamAllowListMatchesTheFixture() {
        assertEquals(document().recordedParams, ActionTraceParams.RECORDED)
    }

    @Test
    fun everyFixtureCaseDiffsAsSpecified() {
        val failures = ArrayList<String>()
        for (case in cases()) {
            val actual = ActionTraceDiff.compare(case.before, case.after, case.maxChanges)
            if (actual != case.expect) {
                failures.add(
                    "  - ${case.name}\n" +
                        "      why:      ${case.why}\n" +
                        "      expected: ${case.expect.joinToString("\n                ") { it.render() }}\n" +
                        "      actual:   ${actual.joinToString("\n                ") { it.render() }}"
                )
            }
        }
        if (failures.isNotEmpty()) {
            fail("action-trace diff disagreed with the fixture table:\n" + failures.joinToString("\n"))
        }
    }

    /**
     * A node identified only by long text is clipped by CODE POINT. Pinned
     * separately from the table because the fixture's astral-plane case proves
     * the boundary but not the unit: `take(60)` on UTF-16 would pass a
     * BMP-only case and only diverge from Swift once an emoji appears.
     */
    @Test
    fun identityTextIsClippedByCodePointNotUtf16Unit() {
        val emoji = "🧾" // U+1F9FE, one code point, two UTF-16 units
        val body = emoji + "x".repeat(80)
        val node = Node(ref = "r1", kind = NodeKind.view, typeName = "TextView", text = body)
        val before = snapshotOf(node.copy(isVisible = false))
        val after = snapshotOf(node)

        val identity = ActionTraceDiff.compare(before, after)
            .first { it.ref == "r1" }
            .node
            ?: fail("an anonymous node's text should have been carried as identity")

        val clipped = identity.text ?: fail("expected clipped identity text")
        // 60 code points kept, then the ellipsis. In UTF-16 that is 61 units,
        // because the emoji occupies two of them.
        assertClip(clipped, expectedCodePoints = ActionTraceDiff.IDENTITY_TEXT_LIMIT)
        if (!clipped.startsWith(emoji)) fail("the emoji must survive whole, not split: $clipped")
    }

    private fun assertClip(clipped: String, expectedCodePoints: Int) {
        val withoutEllipsis = clipped.removeSuffix("…")
        if (withoutEllipsis == clipped) fail("expected a trailing ellipsis on clipped text: $clipped")
        val actual = withoutEllipsis.codePointCount(0, withoutEllipsis.length)
        if (actual != expectedCodePoints) {
            fail("expected $expectedCodePoints code points before the ellipsis, got $actual: $clipped")
        }
    }

    private fun snapshotOf(node: Node): Snapshot = Snapshot(
        capturedAtMillis = 1L,
        screen = ScreenInfo(Size(100.0, 100.0), density = 1.0),
        rootRef = "r0",
        nodes = linkedMapOf(
            "r0" to Node(
                ref = "r0",
                kind = NodeKind.application,
                typeName = "app",
                children = listOf(node.ref),
            ),
            node.ref to node,
        ),
    )

    private fun ActionTraceChange.render(): String =
        "${ref ?: "-"}.$field ${before ?: "-"} -> ${after ?: "-"}" +
            (node?.render()?.let { " [$it]" } ?: "") +
            (note?.let { " ($it)" } ?: "")

    private fun ActionTraceNodeIdentity.render(): String = listOfNotNull(
        testId?.let { "testId=$it" },
        resourceId?.let { "id=$it" },
        label?.let { "label=$it" },
        role?.let { "role=$it" },
        text?.let { "text=$it" },
    ).joinToString(" ")
}
