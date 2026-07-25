package dev.reticle.cli

import dev.reticle.core.Point
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * `tap --settle`'s loop: hold the tap until the resolved point repeats, so a popup
 * still sliding in cannot make the touch land on the neighbouring row. The clock and
 * the resolver are injected, so these run without a device.
 */
class SettleTargetTest {

    @Test
    fun reportsTheRestingPointOnceTheTargetStopsMoving() {
        // The shape measured on a device: a menu captured mid-slide, then at rest.
        val positions = mutableListOf(1474.0, 1612.0, 1612.0)
        val settled = settle(first = 1396.0) { positions.removeFirstOrNull()?.let { target(it) } }

        assertTrue(settled.stable)
        // The tap must be aimed where the row ENDED UP, not where it was first seen.
        assertEquals(1612.0, settled.target.point.y)
    }

    @Test
    fun givesUpWithTheFreshestPointWhenTheTargetNeverStops() {
        var y = 100.0
        val settled = settle(first = y) { y += 25.0; target(y) }

        // Honest, not silent: it still taps, and says the point may be stale.
        assertFalse(settled.stable)
        assertTrue(settled.target.point.y > 100.0)
    }

    @Test
    fun keepsTheLastKnownPointWhenTheTargetVanishesMidSettle() {
        // A popup dismissed under us: not a failure of the tap yet.
        val settled = settle(first = 480.0) { null }

        assertFalse(settled.stable)
        assertEquals(480.0, settled.target.point.y)
    }

    @Test
    fun aZeroBudgetNeverPollsAndNeverBlocks() {
        var polls = 0
        val settled = settleTarget(
            first = target(10.0),
            budgetMs = 0L,
            pollMs = 150L,
            nowMs = { 0L },
            sleep = {},
        ) { polls++; target(10.0) }

        assertEquals(0, polls)
        assertFalse(settled.stable)
    }

    @Test
    fun subPixelDriftCountsAsSettled() {
        // Rounding noise between two captures is not movement.
        val settled = settle(first = 500.0) { target(500.4) }

        assertTrue(settled.stable)
    }

    /** Runs the loop on a virtual clock that advances one poll per iteration. */
    private fun settle(
        first: Double,
        budgetMs: Long = 2_000L,
        resolve: () -> ResolvedInputTarget?,
    ): SettledInputTarget {
        var clock = 0L
        return settleTarget(
            first = target(first),
            budgetMs = budgetMs,
            pollMs = 150L,
            nowMs = { clock },
            sleep = { clock += it },
            resolve = resolve,
        )
    }

    private fun target(y: Double) = ResolvedInputTarget(Point(200.0, y), "label", "r53")
}
