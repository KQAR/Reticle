package dev.reticle.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Tests for substring -> screen-rect resolution. This is the logic an agent
 * relies on to tap a specific phrase/link inside one text node, so the
 * per-character X mapping must be exact (not equal-width interpolation).
 */
class CharGridTest {

    // A single line "abcd" whose 4 chars sit at x = 10,20,40,80,100 (uneven
    // widths — proves we read real offsets, not interpolate).
    private fun unevenLine() = CharLine(
        line = 0,
        start = 0,
        end = 4,
        top = 100.0,
        bottom = 150.0,
        xOffsets = listOf(10.0, 20.0, 40.0, 80.0, 100.0),
    )

    @Test
    fun subRange_usesRealOffsets_notInterpolation() {
        val line = unevenLine()
        // chars [2,4) => from xOffsets[2]=40 to xOffsets[4]=100
        val rect = assertNotNull(line.subRange(2, 4))
        assertEquals(40.0, rect.x)
        assertEquals(60.0, rect.width)
        assertEquals(100.0, rect.y)
        assertEquals(50.0, rect.height)
    }

    @Test
    fun subRange_singleChar() {
        val rect = assertNotNull(unevenLine().subRange(1, 2))
        assertEquals(20.0, rect.x)   // xOffsets[1]
        assertEquals(20.0, rect.width) // xOffsets[2]-xOffsets[1] = 40-20
    }

    @Test
    fun subRange_clampsOutOfRange() {
        // Asking beyond the line end clamps to the last boundary.
        val rect = assertNotNull(unevenLine().subRange(3, 99))
        assertEquals(80.0, rect.x)
        assertEquals(20.0, rect.width) // up to xOffsets[4]=100
    }

    @Test
    fun subRange_emptyOrDisjointReturnsNull() {
        assertNull(unevenLine().subRange(2, 2))   // empty
        assertNull(unevenLine().subRange(10, 12)) // entirely past the line
    }

    @Test
    fun rangeRects_multiLinkRow_distinctRects() {
        // Two visual lines: "AB" then "CD". A multi-link row must resolve each
        // phrase to its OWN line's rect, never a collapsed full-width block.
        val grid = CharGrid(
            text = "ABCD",
            lines = listOf(
                CharLine(0, 0, 2, top = 0.0, bottom = 10.0, xOffsets = listOf(0.0, 30.0, 60.0)),
                CharLine(1, 2, 4, top = 10.0, bottom = 20.0, xOffsets = listOf(0.0, 25.0, 50.0)),
            ),
        )
        // "C" is char index 2, on line 1.
        val rects = grid.rangeRects(2, 3)
        assertEquals(1, rects.size)
        assertEquals(10.0, rects[0].y) // line 1
        assertEquals(0.0, rects[0].x)
        assertEquals(25.0, rects[0].width)
    }

    @Test
    fun rangeRects_spanningTwoLines_yieldsRectPerLine() {
        val grid = CharGrid(
            text = "ABCD",
            lines = listOf(
                CharLine(0, 0, 2, top = 0.0, bottom = 10.0, xOffsets = listOf(0.0, 30.0, 60.0)),
                CharLine(1, 2, 4, top = 10.0, bottom = 20.0, xOffsets = listOf(0.0, 25.0, 50.0)),
            ),
        )
        // Range [1,3) covers char 1 (line 0) and char 2 (line 1).
        val rects = grid.rangeRects(1, 3)
        assertEquals(2, rects.size)
        assertTrue(rects.any { it.y == 0.0 })
        assertTrue(rects.any { it.y == 10.0 })
    }
}
