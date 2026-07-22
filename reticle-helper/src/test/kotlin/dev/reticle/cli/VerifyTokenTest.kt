package dev.reticle.cli

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

/**
 * Tests for [parseVerifyToken] — the `act --verify` selector resolver. Pure
 * string→selector logic, no device.
 */
class VerifyTokenTest {

    @Test
    fun falseToken_isNotRequested() {
        assertNull(parseVerifyToken("false", null, null, null, null))
    }

    @Test
    fun hashToken_isTestId() {
        val sel = parseVerifyToken("#rata", null, null, null, null)!!
        assertEquals("rata", sel.testId)
        assertNull(sel.resourceId)
        assertNull(sel.ref)
    }

    @Test
    fun atToken_isResourceId() {
        val sel = parseVerifyToken("@rata", null, null, null, null)!!
        assertEquals("rata", sel.resourceId)
        assertNull(sel.testId)
    }

    @Test
    fun bareToken_isRef() {
        val sel = parseVerifyToken("r129", null, null, null, null)!!
        assertEquals("r129", sel.ref)
        assertNull(sel.testId)
        assertNull(sel.resourceId)
    }

    @Test
    fun trueToken_reusesActionSelector() {
        val sel = parseVerifyToken("true", null, "btnWithdraw", null, null)!!
        assertEquals("btnWithdraw", sel.resourceId)
    }

    @Test
    fun trueToken_reusesCssSelector() {
        val sel = parseVerifyToken("true", null, null, "#web-pay", null)!!
        assertEquals("#web-pay", sel.cssSelector)
    }

    @Test
    fun cssToken_isCssSelector() {
        val sel = parseVerifyToken("css=#web-status", null, null, null, null)!!
        assertEquals("#web-status", sel.cssSelector)
    }

    @Test
    fun trueToken_withoutActionSelector_fails() {
        // A raw --point gesture has no node to watch.
        assertFailsWith<CliError> { parseVerifyToken("true", null, null, null, null) }
    }

    @Test
    fun testIdEqualsToken_isTestId() {
        val sel = parseVerifyToken("testId=checkout.status", null, null, null, null)!!
        assertEquals("checkout.status", sel.testId)
        assertNull(sel.ref)
    }

    @Test
    fun resourceIdEqualsToken_isResourceId() {
        val sel = parseVerifyToken("resourceId=btnWithdraw", null, null, null, null)!!
        assertEquals("btnWithdraw", sel.resourceId)
        assertNull(sel.ref)
    }

    @Test
    fun refEqualsToken_isRef() {
        val sel = parseVerifyToken("ref=r129", null, null, null, null)!!
        assertEquals("r129", sel.ref)
    }

    @Test
    fun unknownKeyEqualsToken_failsLoudly() {
        // Would otherwise become a never-matching ref and report
        // "node not present" no matter what the UI does.
        assertFailsWith<CliError> { parseVerifyToken("testid=checkout.status", null, null, null, null) }
    }
}
