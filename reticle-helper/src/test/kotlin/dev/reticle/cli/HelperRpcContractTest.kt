package dev.reticle.cli

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * The third leg of the helper RPC contract.
 *
 * The method list lives in three places by necessity: the table in
 * `reticle-protocol/helper-rpc.md` (the authority), the Swift host's `HelperMethod`
 * enum (the caller's view), and `Helper.dispatch` (the implementation). The Swift
 * suite `HelperMethodContractTests` pins the first two against each other and says
 * in its own comment that the third is checked by nothing — it answers "unknown
 * method" at runtime for anything it does not implement.
 *
 * At runtime means on a device, and CI has no device. So a method added to the
 * protocol and to the Swift enum, but never wired here, merges green and fails in
 * front of a user. This test closes that: it reads the branches of `dispatch`
 * straight out of the source and compares them to the markdown, so no fourth
 * hand-maintained list is introduced to drift on its own.
 */
class HelperRpcContractTest {

    /** `<module>/build/...` is the test working dir's sibling; walk up to the repo. */
    private fun repoRoot(): File {
        var dir = File(".").absoluteFile
        while (dir.parentFile != null) {
            if (File(dir, "reticle-protocol/helper-rpc.md").exists()) return dir
            dir = dir.parentFile
        }
        fail("could not locate the repo root from ${File(".").absolutePath}")
    }

    /**
     * Branch labels of the `when (method)` in Helper.kt — lines shaped
     * `"<name>" -> …`, up to the `else ->` that ends the block.
     */
    private fun implementedMethods(): Set<String> {
        val source = File(repoRoot(), "reticle-helper/src/main/kotlin/dev/reticle/cli/Helper.kt")
        assertTrue(source.exists(), "Helper.kt moved; this contract test must move with it")
        val lines = source.readLines()
        val start = lines.indexOfFirst { it.contains("fun dispatch(method: String") }
        assertTrue(start >= 0, "no `dispatch(method:` in Helper.kt — the contract test cannot read it")
        val branch = Regex("""^\s*"([A-Za-z]+)"\s*->""")
        val found = linkedSetOf<String>()
        for (line in lines.drop(start + 1)) {
            if (line.contains("else ->")) break
            branch.find(line)?.let { found.add(it.groupValues[1]) }
        }
        assertTrue(found.isNotEmpty(), "parsed no method branches out of Helper.dispatch")
        return found
    }

    /** Rows of the Methods table look like: | `status` | `package?` | … — same parse as the Swift twin. */
    private fun documentedMethods(): Set<String> {
        val doc = File(repoRoot(), "reticle-protocol/helper-rpc.md").readText()
        val found = linkedSetOf<String>()
        for (line in doc.lineSequence().filter { it.startsWith("| `") }) {
            val name = line.drop(3).substringBefore('`')
            if (name.isEmpty() || name.contains(' ')) continue
            found.add(name)
        }
        assertTrue(found.isNotEmpty(), "no method rows parsed out of helper-rpc.md")
        return found
    }

    @Test
    fun dispatchImplementsExactlyTheDocumentedWireContract() {
        val implemented = implementedMethods()
        val documented = documentedMethods()
        assertEquals(
            emptySet(),
            documented - implemented,
            "helper-rpc.md documents methods Helper.dispatch does not implement — the Swift host " +
                "would call them and get `unknown method` on a device",
        )
        assertEquals(
            emptySet(),
            implemented - documented,
            "Helper.dispatch implements methods helper-rpc.md does not document — an undocumented " +
                "method is one the daemon's `/helper/rpc` broker refuses, so it is unreachable anyway",
        )
    }

    @Test
    fun anUndocumentedMethodIsAnswered_notCrashedOn() {
        // The other half of the contract's promise: one bad call must not take the
        // long-lived helper down mid-session.
        val response = Helper.handleLine("""{"id":7,"method":"exec","params":{}}""")
        assertTrue(response.contains("\"ok\":false"), response)
        assertTrue(response.contains("unknown method"), response)
    }
}
