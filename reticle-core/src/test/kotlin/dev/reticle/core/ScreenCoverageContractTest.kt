package dev.reticle.core

import kotlinx.serialization.Serializable
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * The blind-agent coverage self-report — `ui coverage` and the verdict every
 * coordinate tap carries — driven by the language-neutral fixture at
 * reticle-protocol/fixtures/screen-coverage.cases.json.
 *
 * Same fixture as ReticleProtocol's `ScreenCoverageContractTests`, for the same
 * reason `snapshot-render.cases.json` exists: the Android helper and the iOS host
 * are different binaries, and a report that answers "how much of this screen is
 * unreachable?" differently per platform is worse than no report — an agent would
 * calibrate on one and be wrong on the other.
 */
class ScreenCoverageContractTest {

    @Serializable
    private data class ExpectedPoint(
        val x: Double,
        val y: Double,
        val covered: Boolean,
        val reason: String,
        val ref: String? = null,
        val selector: String? = null,
        val warning: String,
    )

    @Serializable
    private data class Case(
        val name: String,
        val report: List<String>,
        val points: List<ExpectedPoint>,
        val snapshot: Snapshot,
    )

    @Serializable
    private data class Cases(val cases: List<Case>)

    private fun cases(): List<Case> {
        val text = javaClass.classLoader
            .getResourceAsStream("fixtures/screen-coverage.cases.json")
            ?.bufferedReader()?.readText()
            ?: fail("missing fixtures/screen-coverage.cases.json on the test classpath")
        return ReticleJson.instance.decodeFromString(Cases.serializer(), text).cases
    }

    @Test
    fun everyFixtureCaseReportsAsSpecified() {
        val failures = ArrayList<String>()
        for (case in cases()) {
            val actual = Render.coverage(case.snapshot).lines()
            if (actual != case.report) {
                failures.add(
                    "  - ${case.name} [report]\n" +
                        "      expected:\n" + case.report.joinToString("\n") { "        $it" } + "\n" +
                        "      actual:\n" + actual.joinToString("\n") { "        $it" }
                )
            }
            for (point in case.points) {
                val verdict = ScreenCoverage.at(case.snapshot, point.x, point.y)
                val got = listOf(
                    verdict.covered.toString(), verdict.reason,
                    verdict.ref ?: "-", verdict.selector ?: "-", verdict.warning(),
                )
                val want = listOf(
                    point.covered.toString(), point.reason,
                    point.ref ?: "-", point.selector ?: "-", point.warning,
                )
                if (got != want) {
                    failures.add(
                        "  - ${case.name} [point ${point.x.toInt()},${point.y.toInt()}]\n" +
                            "      expected: $want\n      actual:   $got"
                    )
                }
            }
        }
        if (failures.isNotEmpty()) {
            fail("coverage diverged from the fixture:\n" + failures.joinToString("\n"))
        }
    }

    @Test
    fun theFixtureCoversEveryVerdictTheReportCanReach() {
        // Each of these is a DIFFERENT response by the agent reading it: a covered
        // point means drop the coordinate, a boundary means keep it, inert means
        // look again, nothing-captured means the screen moved. A verdict that stops
        // being pinned collapses into whichever neighbour still is.
        val reasons = cases().flatMap { case -> case.points.map { it.reason } }
        for (reason in listOf(
            ScreenCoverage.REASON_ADDRESSABLE,
            ScreenCoverage.REASON_CROSS_ORIGIN,
            ScreenCoverage.REASON_CONTAINER_ONLY,
            ScreenCoverage.REASON_NOT_INTERACTIVE,
            ScreenCoverage.REASON_NOTHING_CAPTURED,
            ScreenCoverage.REASON_OFF_SCREEN,
            ScreenCoverage.REASON_WHEEL,
        )) {
            assertTrue(reasons.any { it == reason || it.startsWith("$reason(") }, "no case pins '$reason'")
        }
        assertTrue(reasons.any { it.startsWith("${ScreenCoverage.REASON_DOM_CAPPED}(") }, "no case pins a capped DOM walk")
        val selectors = cases().flatMap { case -> case.points.mapNotNull { it.selector } }
        for (flag in listOf("--test-id", "--css", "--label")) {
            assertTrue(selectors.any { it.startsWith(flag) }, "no case pins the '$flag' hint")
        }
    }

    @Test
    fun aScreenSizedTappableContainerIsNotCoverForThePointsInsideIt() {
        // The measurement that reshaped the rule: an Android `WebView` is focusable,
        // clickable and carries a resource id, so it passes every test a control
        // does while covering the display. Counted as cover, it reported a real
        // hybrid screen as 100% addressable — turning the one number that measures
        // the blind-agent contract into a constant. A selector tap on it lands on
        // ITS centre, which is not where the agent was aiming.
        val web = Node(
            ref = "wv",
            parentRef = "r0",
            kind = NodeKind.view,
            typeName = "android.webkit.WebView",
            role = "webView",
            resourceId = "webview",
            frame = Rect(0.0, 0.0, 100.0, 100.0),
            isInteractive = true,
        )
        val root = Node(
            ref = "r0",
            kind = NodeKind.application,
            typeName = "android.app.Application",
            role = "application",
            children = listOf("wv"),
        )
        val snapshot = Snapshot(
            capturedAtMillis = 0,
            screen = ScreenInfo(Size(100.0, 100.0), 3.0),
            rootRef = "r0",
            nodes = listOf(root, web).associateBy { it.ref },
        )
        val verdict = ScreenCoverage.at(snapshot, 90.0, 90.0)
        assertEquals(ScreenCoverage.REASON_CONTAINER_ONLY, verdict.reason)
        assertEquals("wv", verdict.ref)
        assertTrue(verdict.detail.contains("(50,50)"), "the container's own tap point must be stated")
        // And the whole-screen number agrees: the container's interior is the gap.
        val report = ScreenCoverage.of(snapshot)
        assertEquals(0, report.addressableCells)
        assertEquals(report.touchRelevantCells, report.unreachableCells)
    }

    @Test
    fun aCheckThatCouldNotRunSaysSoInsteadOfGoingMissing() {
        // The verdict is attached to a gesture that dispatches whatever happens, so
        // the failure mode to guard is an ABSENT verdict: no line at all reads as
        // "the coordinate was fine" and puts the silence right back.
        val verdict = ScreenCoverage.unavailable(10.0, 20.0, "the runtime was unreachable")
        assertEquals(ScreenCoverage.REASON_UNAVAILABLE, verdict.reason)
        assertEquals(
            "could not check whether a selector covers (10,20) — the runtime was unreachable",
            verdict.warning(),
        )
        // The wire keys a host prints from, spelled once for both platforms.
        val wire = verdict.wire()
        for (key in listOf("x", "y", "covered", "reason", "detail", "warning")) {
            assertTrue(wire.containsKey(key), "the coverage wire object dropped '$key'")
        }
    }

    @Test
    fun theFixtureCoversBothPlatforms() {
        val cases = cases()
        assertTrue(cases.any { it.snapshot.platform == "android" }, "no android case")
        assertTrue(cases.any { it.snapshot.platform == "ios" }, "no iOS case")
    }

    @Test
    fun aScreenWithNothingOnItIsHundredPercentRatherThanUndefined() {
        // The empty-screen divide-by-zero: an agent reading `0%` on a blank screen
        // would file a coverage gap against a screen that has nothing to cover.
        val root = Node(
            ref = "r0",
            kind = NodeKind.application,
            typeName = "android.app.Application",
            role = "application",
        )
        val snapshot = Snapshot(
            capturedAtMillis = 0,
            screen = ScreenInfo(Size(64.0, 64.0), 3.0),
            rootRef = "r0",
            nodes = mapOf("r0" to root),
        )
        val report = ScreenCoverage.of(snapshot)
        assertEquals(0, report.touchRelevantCells)
        assertEquals(100, report.addressablePercent)
        assertTrue(
            report.render().contains("no touch-relevant cells on this screen"),
            "an empty screen must say so instead of reporting a share of nothing",
        )
    }

    @Test
    fun aLaterDrawnCoverDecidesTheVerdictAtItsOwnPoint() {
        // Same relation `CompactObservation.occludedBy` uses one level down: sibling
        // order IS draw order, so the topmost node at a point is the one a touch
        // meets. Without this the verdict could name a node the touch never reaches
        // — and then a coordinate over a covered button would read as "you didn't
        // need --point" while the tap actually lands on the cover.
        fun node(ref: String, interactive: Boolean, testId: String?) = Node(
            ref = ref,
            parentRef = "w1",
            kind = NodeKind.view,
            typeName = "android.widget.FrameLayout",
            role = "view",
            testId = testId,
            frame = Rect(0.0, 0.0, 64.0, 64.0),
            isInteractive = interactive,
        )
        val window = Node(
            ref = "w1",
            parentRef = "r0",
            kind = NodeKind.window,
            typeName = "com.android.internal.policy.DecorView",
            role = "window",
            frame = Rect(0.0, 0.0, 64.0, 64.0),
            children = listOf("under", "over"),
        )
        val root = Node(
            ref = "r0",
            kind = NodeKind.application,
            typeName = "android.app.Application",
            role = "application",
            children = listOf("w1"),
        )
        val nodes = listOf(root, window, node("under", true, "under"), node("over", true, "over"))
        val snapshot = Snapshot(
            capturedAtMillis = 0,
            screen = ScreenInfo(Size(64.0, 64.0), 3.0),
            rootRef = "r0",
            nodes = nodes.associateBy { it.ref },
        )
        assertEquals("over", ScreenCoverage.at(snapshot, 32.0, 32.0).ref)
    }
}
