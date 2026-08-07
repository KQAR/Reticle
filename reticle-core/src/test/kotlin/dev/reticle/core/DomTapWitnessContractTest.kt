package dev.reticle.core

import kotlinx.serialization.Serializable
import kotlin.test.Test
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Where a tap actually landed, driven by the language-neutral fixture at
 * reticle-protocol/fixtures/dom-tap-witness.cases.json.
 *
 * Same fixture as ReticleProtocol's `DomTapWitnessContractTests`. A judgement that
 * differed between the two ports would be the worst kind of difference here: the whole
 * point of this evidence is that a missed tap stops being silent, and a port that stayed
 * quiet on a miss would put the silence back on one platform only.
 */
class DomTapWitnessContractTest {

    @Serializable
    private data class ExpectedVerdict(
        val token: String,
        val landedOn: String? = null,
        val at: String? = null,
        val relation: String = "unknown",
    )

    @Serializable
    private data class Probe(val ref: String, val verdict: ExpectedVerdict? = null)

    @Serializable
    private data class Case(val name: String, val probes: List<Probe>, val snapshot: Snapshot)

    @Serializable
    private data class Cases(val cases: List<Case>)

    private fun cases(): List<Case> {
        val text = javaClass.classLoader
            .getResourceAsStream("fixtures/dom-tap-witness.cases.json")
            ?.bufferedReader()?.readText()
            ?: fail("missing fixtures/dom-tap-witness.cases.json on the test classpath")
        return ReticleJson.instance.decodeFromString(Cases.serializer(), text).cases
    }

    @Test
    fun everyFixtureProbeIsJudgedTheWayTheFixtureSays() {
        val failures = ArrayList<String>()
        for (case in cases()) {
            for (probe in case.probes) {
                val got = DomTapWitness.of(case.snapshot, probe.ref)
                val want = probe.verdict
                if (want == null) {
                    if (got != null) failures += "${case.name}: ${probe.ref} expected silence, got $got"
                    continue
                }
                if (got == null) {
                    failures += "${case.name}: ${probe.ref} expected ${want.token}, got silence"
                    continue
                }
                val mismatch = got.token != want.token ||
                    got.landedOn != want.landedOn ||
                    got.at != want.at ||
                    got.relation.name != want.relation
                if (mismatch) failures += "${case.name}: ${probe.ref} wanted $want, got $got"
            }
        }
        assertTrue(failures.isEmpty(), failures.joinToString("\n"))
    }

    /**
     * The prose is duplicated per port (like `DomRectCheck`'s), so what is asserted here
     * is that a reported verdict actually SAYS the two things a caller acts on: where the
     * touch arrived, and what it hit instead.
     */
    @Test
    fun aReportedMissNamesTheCoordinateAndWhatWasHit() {
        val case = cases().first { it.probes.any { p -> p.verdict?.landedOn == "other" } }
        val message = DomTapWitness.describe(case.snapshot, "button")
            ?: fail("a landed-elsewhere verdict must produce a message")
        assertTrue(message.contains("120,270"), message)
        assertTrue(message.contains("#other"), message)
        assertTrue(message.contains("#submit"), message)
    }

    @Test
    fun anAbsentPointerSaysThePageWasNotTouchedAtAll() {
        val case = cases().first { it.probes.any { p -> p.verdict?.token == DomTapWitness.NOT_RECEIVED } }
        val message = DomTapWitness.describe(case.snapshot, "button")
            ?: fail("a not-received verdict must produce a message")
        assertTrue(message.contains("no pointer event"), message)
    }
}
