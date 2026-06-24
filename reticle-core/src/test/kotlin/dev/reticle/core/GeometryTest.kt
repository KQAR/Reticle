package dev.reticle.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class GeometryTest {

    @Test
    fun rectCenters() {
        val r = Rect(x = 10.0, y = 20.0, width = 100.0, height = 40.0)
        assertEquals(60.0, r.centerX)
        assertEquals(40.0, r.centerY)
    }

    @Test
    fun rectContains() {
        val r = Rect(x = 0.0, y = 0.0, width = 100.0, height = 50.0)
        assertTrue(r.contains(0.0, 0.0))     // top-left corner
        assertTrue(r.contains(100.0, 50.0))  // bottom-right corner (inclusive)
        assertTrue(r.contains(50.0, 25.0))   // inside
        assertFalse(r.contains(-1.0, 25.0))  // left of
        assertFalse(r.contains(50.0, 51.0))  // below
    }
}
