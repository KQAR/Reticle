package dev.reticle.core

import kotlinx.serialization.Serializable
import kotlin.test.Test
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Where a tap can actually land, driven by the language-neutral fixture at
 * reticle-protocol/fixtures/tap-reach.cases.json.
 *
 * Same fixture as ReticleProtocol's `TapReachContractTests`, for the reason every
 * shared fixture exists: the Android helper and the iOS host are different
 * binaries, and a tap that is refused on one platform and dispatched into empty
 * space on the other is the worst kind of difference — the flow "works" on one
 * device and silently does nothing on the other.
 */
class TapReachContractTest {

    @Serializable
    private data class ExpectedTarget(
        val ref: String,
        /** "x,y", or absent when the fixture expects a refusal. */
        val point: String? = null,
        val adjusted: Boolean = false,
        val reason: String? = null,
        val by: String? = null,
        val explain: String? = null,
    )

    @Serializable
    private data class Case(
        val name: String,
        val targets: List<ExpectedTarget>,
        val snapshot: Snapshot,
    )

    @Serializable
    private data class Cases(val cases: List<Case>)

    private fun cases(): List<Case> {
        val text = javaClass.classLoader
            .getResourceAsStream("fixtures/tap-reach.cases.json")
            ?.bufferedReader()?.readText()
            ?: fail("missing fixtures/tap-reach.cases.json on the test classpath")
        return ReticleJson.instance.decodeFromString(Cases.serializer(), text).cases
    }

    @Test
    fun everyFixtureTargetResolvesWhereTheFixtureSays() {
        val failures = ArrayList<String>()
        for (case in cases()) {
            for (target in case.targets) {
                val reach = TapReach.of(case.snapshot, target.ref)
                    ?: fail("${case.name}: ${target.ref} is not in the fixture snapshot")
                val got = listOf(
                    reach.point?.let { "${it.x.toInt()},${it.y.toInt()}" } ?: "-",
                    reach.adjusted.toString(),
                    reach.reason ?: "-",
                    reach.by ?: "-",
                    if (reach.adjusted) reach.explain(target.ref) else "-",
                )
                val want = listOf(
                    target.point ?: "-",
                    target.adjusted.toString(),
                    target.reason ?: "-",
                    target.by ?: "-",
                    target.explain ?: "-",
                )
                if (got != want) {
                    failures.add(
                        "  - ${case.name} [${target.ref}]\n" +
                            "      expected: $want\n      actual:   $got"
                    )
                }
            }
        }
        if (failures.isNotEmpty()) {
            fail("tap reach diverged from the fixture:\n" + failures.joinToString("\n"))
        }
    }

    @Test
    fun theFixturePinsBothRefusalsAndTheQuietCase() {
        // Each is a different thing for the caller to do: scroll the page, scroll
        // the container, or nothing at all. The quiet case matters most — a reach
        // note on an ordinary tap would train callers to ignore the field.
        val reasons = cases().flatMap { case -> case.targets.map { it.reason } }
        assertTrue(reasons.any { it == TapReach.UNREACHABLE_OFF_SCREEN }, "no case pins an off-screen refusal")
        assertTrue(reasons.any { it == TapReach.UNREACHABLE_CLIPPED }, "no case pins a clipped refusal")
        val adjusted = cases().flatMap { case -> case.targets.map { it.adjusted } }
        assertTrue(adjusted.any { it }, "no case pins a tap aimed at the visible part")
        assertTrue(adjusted.any { !it }, "no case pins a tap that needed no adjustment")
    }

    @Test
    fun anOrdinaryLayoutParentDoesNotClipItsChildren() {
        // Android views draw outside their parent's bounds all the time
        // (`clipChildren=false`), so treating every ancestor as a clip would MOVE
        // taps that were landing correctly. Only a scroll port, a window and the
        // screen clip — see the class note on TapReach.
        val child = Node(
            ref = "child", parentRef = "box", kind = NodeKind.view, typeName = "android.widget.Button",
            role = "button", frame = Rect(0.0, 40.0, 40.0, 40.0), isInteractive = true,
        )
        val box = Node(
            ref = "box", parentRef = "w1", kind = NodeKind.view, typeName = "android.widget.FrameLayout",
            role = "container", frame = Rect(0.0, 0.0, 40.0, 40.0), children = listOf("child"),
        )
        val window = Node(
            ref = "w1", parentRef = "r0", kind = NodeKind.window, typeName = "DecorView", role = "window",
            frame = Rect(0.0, 0.0, 128.0, 128.0), children = listOf("box"),
        )
        val root = Node(
            ref = "r0", kind = NodeKind.application, typeName = "App", role = "application",
            children = listOf("w1"),
        )
        val snapshot = Snapshot(
            capturedAtMillis = 0,
            platform = "android",
            screen = ScreenInfo(size = Size(128.0, 128.0), density = 3.0),
            rootRef = "r0",
            nodes = listOf(root, window, box, child).associateBy { it.ref },
        )
        val reach = TapReach.of(snapshot, "child")
        assertTrue(reach?.adjusted == false, "a plain layout parent must not clip its child's tap point")
        assertTrue(reach?.point?.y == 60.0, "the tap must stay on the child's own centre")
    }
}
