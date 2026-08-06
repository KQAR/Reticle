package dev.reticle.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** Twin: `DomScrollTests` in ReticleProtocol. Same numbers, same verdicts. */
class DomScrollTest {

    @Test
    fun anElementWithNoScrollPortHasNoCapability() {
        assertNull(
            DomScroll.fromMetrics(
                scrollLeft = -1.0, scrollTop = -1.0,
                scrollWidth = -1.0, scrollHeight = -1.0,
                clientWidth = -1.0, clientHeight = -1.0,
            ),
        )
    }

    @Test
    fun aPortThatCannotMoveIsNotReportedAsScrollable() {
        // The shape that made a bare `scrollHeight > clientHeight` useless: sub-pixel
        // layout leaves fractions of overflow on panes that cannot scroll at all.
        assertNull(
            DomScroll.fromMetrics(
                scrollLeft = 0.0, scrollTop = 0.0,
                scrollWidth = 300.4, scrollHeight = 300.6,
                clientWidth = 300.0, clientHeight = 300.0,
            ),
        )
    }

    @Test
    fun travelIsReportedPerDirectionFromThePortsOwnNumbers() {
        assertEquals(
            ScrollInfo(canScrollDown = true),
            DomScroll.fromMetrics(
                scrollLeft = 0.0, scrollTop = 0.0,
                scrollWidth = 300.0, scrollHeight = 900.0,
                clientWidth = 300.0, clientHeight = 300.0,
            ),
        )
        // Mid-scroll: both ways, on both axes.
        assertEquals(
            ScrollInfo(
                canScrollUp = true, canScrollDown = true,
                canScrollLeft = true, canScrollRight = true,
            ),
            DomScroll.fromMetrics(
                scrollLeft = 100.0, scrollTop = 300.0,
                scrollWidth = 900.0, scrollHeight = 900.0,
                clientWidth = 300.0, clientHeight = 300.0,
            ),
        )
        // At the end: the only travel left is back.
        assertEquals(
            ScrollInfo(canScrollUp = true),
            DomScroll.fromMetrics(
                scrollLeft = 0.0, scrollTop = 600.0,
                scrollWidth = 300.0, scrollHeight = 900.0,
                clientWidth = 300.0, clientHeight = 300.0,
            ),
        )
    }
}
