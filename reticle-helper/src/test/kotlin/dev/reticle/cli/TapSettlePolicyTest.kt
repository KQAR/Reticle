package dev.reticle.cli

import dev.reticle.core.Point
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * [TapSettlePolicy]: when a selector tap re-resolves before dispatching, and what
 * it reports when the re-resolve moved the point.
 *
 * The behaviour being pinned is the DEFAULT — a selector tap confirms its point
 * even with no flag — because the failure it prevents is silent: a rect made
 * stale by an earlier relayout sends the touch to the neighbouring control and
 * the command still reports success.
 */
class TapSettlePolicyTest {

    @Test
    fun aPlainSelectorTapConfirmsByDefault() {
        val plan = TapSettlePolicy.plan(rawPoint = false, settle = false, noSettle = false, timeoutMs = null)
        assertTrue(plan.confirm)
        assertEquals(TapSettlePolicy.CONFIRM_BUDGET_MS, plan.budgetMs)
    }

    @Test
    fun explicitSettleGetsTheFullBudget() {
        // `--settle` now means "this target IS animating in", not "confirm at all".
        val plan = TapSettlePolicy.plan(rawPoint = false, settle = true, noSettle = false, timeoutMs = null)
        assertTrue(plan.confirm)
        assertEquals(TapSettlePolicy.SETTLE_BUDGET_MS, plan.budgetMs)
    }

    @Test
    fun noSettleOptsOutEntirely() {
        val plan = TapSettlePolicy.plan(rawPoint = false, settle = false, noSettle = true, timeoutMs = null)
        assertFalse(plan.confirm)
    }

    @Test
    fun aRawPointNeverConfirms() {
        // A coordinate has nothing to re-resolve — there is no selector to ask again.
        assertFalse(TapSettlePolicy.plan(rawPoint = true, settle = false, noSettle = false, timeoutMs = null).confirm)
        assertFalse(TapSettlePolicy.plan(rawPoint = true, settle = false, noSettle = false, timeoutMs = 5_000).confirm)
    }

    @Test
    fun anExplicitTimeoutWinsOverBothDefaults() {
        assertEquals(
            250L,
            TapSettlePolicy.plan(rawPoint = false, settle = false, noSettle = false, timeoutMs = 250).budgetMs,
        )
        assertEquals(
            250L,
            TapSettlePolicy.plan(rawPoint = false, settle = true, noSettle = false, timeoutMs = 250).budgetMs,
        )
    }

    @Test
    fun noSettleBeatsSettleWhenBothAreSomehowSet() {
        // A batch step assembled from JSON can carry both; refusing to confirm is
        // the reading that cannot surprise a caller with extra latency.
        assertFalse(TapSettlePolicy.plan(rawPoint = false, settle = true, noSettle = true, timeoutMs = null).confirm)
    }

    @Test
    fun movedBy_reportsTheDeltaWhenTheRectShifted() {
        // The measured case: the page had scrolled up ~161px after a `type`.
        assertEquals("0,-161", TapSettlePolicy.movedBy(Point(540.0, 1362.0), Point(540.0, 1201.0)))
    }

    @Test
    fun movedBy_isSilentOnAStableRect() {
        assertNull(TapSettlePolicy.movedBy(Point(540.0, 1201.0), Point(540.0, 1201.0)))
    }

    @Test
    fun movedBy_ignoresSubPixelJitter() {
        // Rounding in the resolver is not a relayout; reporting it would train a
        // caller to ignore the field that matters.
        assertNull(TapSettlePolicy.movedBy(Point(540.0, 1201.0), Point(540.4, 1201.6)))
    }
}
