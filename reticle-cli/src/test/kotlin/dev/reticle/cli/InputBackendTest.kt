package dev.reticle.cli

import dev.reticle.cli.platform.android.InputBackend
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Tests for [InputBackend.isAsciiTypeable] — the gate that decides whether
 * `act type` can use the agent-free `adb input text` fast path (ASCII only) or
 * must route through the agent clipboard + paste path (non-ASCII). `adb input
 * text` silently drops anything outside printable ASCII, so this classification
 * is what keeps non-ASCII typing from failing silently.
 */
class InputBackendTest {

    @Test
    fun plainAsciiIsTypeable() {
        assertTrue(InputBackend.isAsciiTypeable("hello world 123"))
        assertTrue(InputBackend.isAsciiTypeable("user@example.com"))
        assertTrue(InputBackend.isAsciiTypeable("a-b_c (d) & e \"f\" 'g'"))
    }

    @Test
    fun cjkIsNotTypeable() {
        assertFalse(InputBackend.isAsciiTypeable("用户协议"))
        assertFalse(InputBackend.isAsciiTypeable("hello 世界"))
    }

    @Test
    fun accentedLatinIsNotTypeable() {
        assertFalse(InputBackend.isAsciiTypeable("Política"))
        assertFalse(InputBackend.isAsciiTypeable("Zażółć gęślą jaźń"))
    }

    @Test
    fun emojiIsNotTypeable() {
        assertFalse(InputBackend.isAsciiTypeable("nice 👍"))
    }

    @Test
    fun controlCharsAreNotAsciiTypeable() {
        // Tab / newline are outside the 0x20..0x7E printable range `input text`
        // handles, so they don't qualify for the fast path.
        assertFalse(InputBackend.isAsciiTypeable("line1\nline2"))
        assertFalse(InputBackend.isAsciiTypeable("col1\tcol2"))
    }

    @Test
    fun emptyStringIsTriviallyTypeable() {
        assertTrue(InputBackend.isAsciiTypeable(""))
    }
}
