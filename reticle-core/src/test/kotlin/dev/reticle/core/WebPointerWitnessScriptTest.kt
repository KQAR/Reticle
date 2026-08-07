package dev.reticle.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * The pointer witness is one file with two embeddings, same rule as the traversal —
 * plus the guard the traversal's own test cannot carry.
 *
 * This is the ONE script Reticle runs in a page that writes, so what has to be pinned
 * is the size of that write: it may add listeners and it may not touch anything else.
 * A witness that quietly grew a `preventDefault` would suppress the app's own handler
 * and turn the tool into the thing it is diagnosing.
 */
class WebPointerWitnessScriptTest {

    @Test
    fun theEmbeddedScriptMatchesTheSharedFile() {
        val expected = javaClass.classLoader
            .getResourceAsStream("scripts/dom-pointer-witness.js")
            ?.bufferedReader()?.readText()
            ?: fail("missing scripts/dom-pointer-witness.js on the test classpath")
        assertEquals(
            expected.trimEnd('\n'),
            WebPointerWitnessScript.SCRIPT.trimEnd('\n'),
            "the embedded pointer witness drifted from reticle-protocol/scripts/dom-pointer-witness.js",
        )
    }

    @Test
    fun theWitnessOnlyObserves() {
        val script = WebPointerWitnessScript.SCRIPT
        // It may add a listener — that is its whole job — and must not interfere with
        // the event it is watching, nor change anything the page can read.
        for (forbidden in listOf(
            "preventDefault",
            "stopPropagation",
            "stopImmediatePropagation",
            ".click(",
            ".focus(",
            ".innerHTML =",
            ".value =",
            "document.write",
        )) {
            assertFalse(
                script.contains(forbidden),
                "the pointer witness must only observe, found '$forbidden'",
            )
        }
        assertTrue(script.contains("addEventListener"), "the witness has to install a listener")
        assertTrue(script.contains("passive"), "an observer must not degrade the page's scrolling")
    }
}
