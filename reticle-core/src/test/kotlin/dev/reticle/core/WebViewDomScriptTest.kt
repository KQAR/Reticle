package dev.reticle.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.fail

/**
 * The DOM traversal script is one file with two embeddings, and this is the Kotlin
 * half of what keeps that true.
 *
 * The script used to be hand-copied between the Android agent and the iOS agent,
 * kept in step by a `KEEP IN SYNC` comment and nothing else — and because Kotlin's
 * raw strings and Swift's multiline literals escape differently, the two copies
 * could not even be compared with a diff. Both sides now embed
 * `reticle-protocol/scripts/dom-traversal.js` and assert it, so editing one
 * embedding (or the file) fails a build instead of quietly giving the two platforms
 * different DOM readings.
 *
 * Embedded rather than read at runtime because the Android agent also ships as a
 * payload dex that `app inject` pushes into a live process, and a dex carries no
 * resources.
 */
class WebViewDomScriptTest {

    @Test
    fun theEmbeddedScriptMatchesTheSharedFile() {
        val expected = javaClass.classLoader
            .getResourceAsStream("scripts/dom-traversal.js")
            ?.bufferedReader()?.readText()
            ?: fail("missing scripts/dom-traversal.js on the test classpath")
        assertEquals(
            expected.trimEnd('\n'),
            WebViewDomScript.SCRIPT.trimEnd('\n'),
            "the embedded DOM traversal script drifted from reticle-protocol/scripts/dom-traversal.js",
        )
    }

    @Test
    fun theScriptIsStillTheReadOnlyTraversalItClaimsToBe() {
        // A cheap guard on the one property the bridge's whole design rests on: the
        // script reads the DOM and must not mutate page state. It is not a parser,
        // so it can only catch the obvious - which is the shape a careless edit
        // takes.
        val script = WebViewDomScript.SCRIPT
        for (mutator in listOf(".click(", ".focus(", "document.write", ".innerHTML =", ".value =")) {
            kotlin.test.assertFalse(
                script.contains(mutator),
                "the traversal script must not mutate the page, found '$mutator'",
            )
        }
    }
}
