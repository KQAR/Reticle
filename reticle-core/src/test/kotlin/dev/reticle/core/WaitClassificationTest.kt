package dev.reticle.core

import kotlinx.serialization.Serializable
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * `act wait`'s outcome table, driven by the language-neutral fixture at
 * reticle-protocol/fixtures/wait-classification.cases.json.
 *
 * The point of reading a fixture instead of writing the cases inline: the iOS
 * path lives in Swift, so the same file drives ReticleProtocol's suite. A branch
 * added to [WaitVerdict.classify] without a case here silently ships unpinned on
 * one of the two platforms — which is exactly how `scroll-to`'s settle logic
 * diverged.
 */
class WaitClassificationTest {

    @Serializable
    private data class Expect(
        val outcome: WaitOutcome,
        val reasons: List<String> = emptyList(),
        val caveats: List<String> = emptyList(),
    )

    @Serializable
    private data class Case(
        val name: String,
        val predicate: WaitPredicate,
        val probe: WaitProbe,
        val quiet: Boolean,
        val expect: Expect,
    )

    @Serializable
    private data class Cases(val cases: List<Case>)

    private fun cases(): List<Case> {
        val text = javaClass.classLoader
            .getResourceAsStream("fixtures/wait-classification.cases.json")
            ?.bufferedReader()?.readText()
            ?: fail("missing fixtures/wait-classification.cases.json on the test classpath")
        return ReticleJson.instance.decodeFromString(Cases.serializer(), text).cases
    }

    @Test
    fun everyFixtureCaseClassifiesAsSpecified() {
        val failures = ArrayList<String>()
        for (case in cases()) {
            val actual = WaitVerdict.classify(case.predicate, case.probe, case.quiet)
            if (actual.outcome != case.expect.outcome ||
                actual.reasons != case.expect.reasons ||
                actual.caveats != case.expect.caveats
            ) {
                failures.add(
                    "  - ${case.name}\n" +
                        "      expected outcome=${case.expect.outcome} reasons=${case.expect.reasons} caveats=${case.expect.caveats}\n" +
                        "      actual   outcome=${actual.outcome} reasons=${actual.reasons} caveats=${actual.caveats}"
                )
            }
        }
        if (failures.isNotEmpty()) {
            fail("wait classification disagreed with the fixture table:\n" + failures.joinToString("\n"))
        }
    }

    @Test
    fun fixtureCoversEveryOutcomeAndReason() {
        // Guards the guard: a table that stopped exercising a branch would pass
        // the test above while proving nothing.
        val cases = cases()
        assertTrue(cases.size >= 20, "expected a broad table, found ${cases.size} cases")
        val outcomes = cases.map { it.expect.outcome }.toSet()
        assertEquals(WaitOutcome.entries.toSet(), outcomes, "every outcome must appear in the table")
        val reasons = cases.flatMap { it.expect.reasons }.toSet()
        for (required in listOf(
            WaitVerdict.REASON_TREE_STILL_CHANGING,
            WaitVerdict.REASON_WINDOW_UNFOCUSED,
            WaitVerdict.REASON_DOM_UNAVAILABLE,
            WaitVerdict.REASON_DOM_UNSUPPORTED_KERNEL,
        )) {
            assertTrue(reasons.contains(required), "no fixture case exercises reason '$required'")
        }
        val caveats = cases.flatMap { it.expect.caveats }.toSet()
        assertTrue(
            caveats.any { it.startsWith(WaitVerdict.CAVEAT_OCCLUDED_PREFIX) },
            "no fixture case exercises an occlusion caveat",
        )
        assertTrue(
            caveats.contains(WaitVerdict.CAVEAT_MAY_BE_UNBOUND),
            "no fixture case exercises the recycled-vs-removed caveat",
        )
        assertTrue(
            caveats.contains(WaitVerdict.CAVEAT_RESOLVED_NOT_VISIBLE),
            "no fixture case exercises the resolvable-but-invisible caveat — the exact case " +
                "the dropped isVisible-based proposal got wrong",
        )
    }

    @Test
    fun occlusionNeverDowngradesASatisfiedPredicate() {
        // The single most important invariant: targetability and visibility are
        // different questions, and a covered node is still targetable. Collapsing
        // them would make every keyboard-covered submit button read as "absent".
        val predicate = WaitPredicate(WaitPredicateKind.appear, Selector(testId = "login.submitButton"))
        val probe = WaitProbe(resolved = true, source = "semantic:testId", occludedBy = "keyboard", digest = "a")
        val verdict = WaitVerdict.classify(predicate, probe, quiet = true)
        assertEquals(WaitOutcome.resolved, verdict.outcome)
        assertEquals(listOf("occluded-by:keyboard"), verdict.caveats)
    }

    @Test
    fun theSuccessTestIsResolutionNotVisibility() {
        // Pins the design correction that made this feature acceptable at all: an
        // earlier `wait --for appears` proposal was dropped because it tested
        // `isVisible` (see HelperScrollTo's and settleInputTarget's comments). The
        // semantic tree keeps hidden-but-labelled nodes, so a node can be
        // invisible AND still be exactly what the next `act` will target — the
        // guarantee a wait has to carry to be worth anything.
        val invisibleButTargetable = WaitProbe(
            resolved = true,
            source = "semantic:testId",
            visible = false,
            digest = "a",
        )
        val appear = WaitPredicate(WaitPredicateKind.appear, Selector(testId = "checkout.status"))
        val appearVerdict = WaitVerdict.classify(appear, invisibleButTargetable, quiet = true)
        assertEquals(WaitOutcome.resolved, appearVerdict.outcome, "an invisible but resolvable node HAS appeared")
        assertEquals(listOf(WaitVerdict.CAVEAT_RESOLVED_NOT_VISIBLE), appearVerdict.caveats)

        // And the mirror image: `gone` is not satisfied by invisibility, because
        // the next act would still resolve and target the node.
        val gone = WaitPredicate(WaitPredicateKind.gone, Selector(testId = "checkout.status"))
        assertEquals(
            WaitOutcome.absent,
            WaitVerdict.classify(gone, invisibleButTargetable, quiet = true).outcome,
            "an invisible but resolvable node is NOT gone",
        )
    }

    @Test
    fun anUnknowableIsNeverAnAbsent() {
        // The whole reason this type is three-state. Each blocking condition alone
        // must lift a miss out of `absent`.
        val predicate = WaitPredicate(WaitPredicateKind.appear, Selector(testId = "x"))
        val blocked = listOf(
            WaitProbe(digest = "a", windowFocused = false),
            WaitProbe(digest = "a", scrollTravel = listOf("@l scroll:down")),
        )
        for (probe in blocked) {
            assertEquals(
                WaitOutcome.unknowable,
                WaitVerdict.classify(predicate, probe, quiet = true).outcome,
                "probe $probe should not be reported as an honest negative",
            )
        }
        // And the same miss with nothing blocking IS an honest negative.
        assertEquals(
            WaitOutcome.absent,
            WaitVerdict.classify(predicate, WaitProbe(digest = "a"), quiet = true).outcome,
        )
    }

    @Test
    fun scheduleBacksOffAsTheBudgetBurns() {
        // A wait's budget is ~10x --verify's, and every poll is a full tree walk
        // plus an adb round trip; a flat interval would be ~200 walks over 30s.
        assertEquals(100L, WaitSchedule.delayMs(0))
        assertEquals(100L, WaitSchedule.delayMs(1_999))
        assertEquals(250L, WaitSchedule.delayMs(2_000))
        assertEquals(250L, WaitSchedule.delayMs(4_999))
        assertEquals(500L, WaitSchedule.delayMs(5_000))
        assertEquals(500L, WaitSchedule.delayMs(60_000))
    }

    @Test
    fun predicateDescribeEchoesWhatWasAsked() {
        // The result must state what was waited on; a caller should never have to
        // infer it. `label` proves describe() delegates to Selector rather than
        // re-spelling the grammar (a re-spelling would render this as "?").
        assertEquals(
            "appear testId=cart.total",
            WaitPredicate(WaitPredicateKind.appear, Selector(testId = "cart.total")).describe(),
        )
        assertEquals(
            "gone css=#toast",
            WaitPredicate(WaitPredicateKind.gone, Selector(cssSelector = "#toast")).describe(),
        )
        assertEquals(
            "text resourceId=status contains \"Paid\"",
            WaitPredicate(
                WaitPredicateKind.text,
                Selector(resourceId = "status"),
                textContains = "Paid",
            ).describe(),
        )
        assertEquals(
            "appear label=Delete item",
            WaitPredicate(WaitPredicateKind.appear, Selector(label = "Delete item")).describe(),
        )
        assertEquals("idle", WaitPredicate(WaitPredicateKind.idle).describe())
    }
}

/**
 * Scroll-travel scoping: which scrollers a wait is allowed to blame.
 *
 * Split out from the fixture table because it is about building the probe from a
 * snapshot, not about classifying one. Both were measured wrong at first: an
 * unscoped list blamed a BACKGROUND window's scroller for a miss in the
 * foreground, which (a) made `absent` nearly unreachable on any app with a
 * scrolling home screen and (b) produced actively misleading advice — a
 * `scroll-to --css` suggestion for a DOM element behind a blocking JS modal.
 */
class WaitScrollTravelTest {

    private fun screen() = ScreenInfo(size = Size(1080.0, 2400.0), density = 3.0)

    /** Root with two window children: a background one and a dialog on top. */
    private fun twoWindowSnapshot(): Snapshot = Snapshot(
        capturedAtMillis = 0,
        screen = screen(),
        rootRef = "app",
        nodes = mapOf(
            "app" to Node(
                ref = "app", kind = NodeKind.application, typeName = "Application",
                children = listOf("bgWindow", "topWindow"),
            ),
            "bgWindow" to Node(
                ref = "bgWindow", parentRef = "app", kind = NodeKind.window,
                typeName = "PhoneWindow", children = listOf("homeScroller"),
                frame = Rect(0.0, 0.0, 1080.0, 2400.0),
            ),
            "homeScroller" to Node(
                ref = "homeScroller", parentRef = "bgWindow", kind = NodeKind.view,
                typeName = "ScrollView", role = "scrollView", testId = "home.scroller",
                frame = Rect(0.0, 0.0, 1080.0, 2400.0), isInteractive = true,
                scroll = ScrollInfo(canScrollDown = true),
            ),
            "topWindow" to Node(
                ref = "topWindow", parentRef = "app", kind = NodeKind.window,
                typeName = "DialogWindow", children = listOf("dialogList"),
                frame = Rect(0.0, 800.0, 1080.0, 800.0),
            ),
            "dialogList" to Node(
                ref = "dialogList", parentRef = "topWindow", kind = NodeKind.view,
                typeName = "RecyclerView", role = "list", testId = "dialog.rows",
                frame = Rect(0.0, 800.0, 1080.0, 800.0), isInteractive = true,
                scroll = ScrollInfo(canScrollDown = true),
            ),
        ),
    )

    @Test
    fun onlyTheTopmostWindowsScrollersAreBlamed() {
        val snapshot = twoWindowSnapshot()
        val travel = WaitProbe.scrollTravelOf(snapshot, CompactObservation.from(snapshot))
        assertEquals(
            listOf("#dialog.rows scroll:down"),
            travel,
            "a background window's scroller can never bring the target into view",
        )
    }

    @Test
    fun aSingleWindowStillReportsItsOwnScroller() {
        val snapshot = twoWindowSnapshot()
        // Drop the dialog window: the home scroller is now the top window's.
        val single = snapshot.copy(
            nodes = snapshot.nodes
                .filterKeys { it != "topWindow" && it != "dialogList" }
                .mapValues { (ref, node) ->
                    if (ref == "app") node.copy(children = listOf("bgWindow")) else node
                },
        )
        assertEquals(
            listOf("#home.scroller scroll:down"),
            WaitProbe.scrollTravelOf(single, CompactObservation.from(single)),
        )
    }

    @Test
    fun aTreeWithNoWindowNodesFallsBackToEveryScroller() {
        // Some iOS trees expose no window node at all. Reporting nothing there would
        // silently drop the honest doubt, so the fallback keeps every scroller.
        val nodes = mapOf(
            "app" to Node(
                ref = "app", kind = NodeKind.application, typeName = "UIApplication",
                children = listOf("scroller"),
            ),
            "scroller" to Node(
                ref = "scroller", parentRef = "app", kind = NodeKind.view,
                typeName = "UIScrollView", role = "scrollView", testId = "list",
                frame = Rect(0.0, 0.0, 390.0, 844.0), isInteractive = true,
                scroll = ScrollInfo(canScrollDown = true),
            ),
        )
        val snapshot = Snapshot(capturedAtMillis = 0, screen = screen(), rootRef = "app", nodes = nodes)
        assertEquals(
            listOf("#list scroll:down"),
            WaitProbe.scrollTravelOf(snapshot, CompactObservation.from(snapshot)),
        )
    }

    @Test
    fun digestIgnoresCaptureTimeButNoticesTheKeyboard() {
        // Quiescence hinges on this: capturedAtMillis must not make every poll look
        // like a change, while a keyboard sliding up must.
        val snapshot = twoWindowSnapshot()
        val later = snapshot.copy(capturedAtMillis = 999_999)
        assertEquals(
            WaitProbe.digestOf(CompactObservation.from(snapshot)),
            WaitProbe.digestOf(CompactObservation.from(later)),
            "a new capture timestamp alone must not read as a screen change",
        )
        val withKeyboard = snapshot.copy(
            screen = screen().copy(keyboard = KeyboardInfo(visible = true, frame = Rect(0.0, 1800.0, 1080.0, 600.0))),
        )
        assertNotEquals(
            WaitProbe.digestOf(CompactObservation.from(snapshot)),
            WaitProbe.digestOf(CompactObservation.from(withKeyboard)),
            "a keyboard appearing IS a screen change, even when no node moved",
        )
    }
}
