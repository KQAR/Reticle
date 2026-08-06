package dev.reticle.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class PortMapTest {

    @Test
    fun derivedPortIsInRange() {
        val packages = listOf(
            "dev.reticle.sample",
            "com.example.lender.debug",
            "com.example.app",
            "a",
            "com.a.very.long.package.name.that.keeps.going",
        )
        for (pkg in packages) {
            val port = PortMap.derivePort(pkg)
            assertTrue(
                port in PortMap.BASE_PORT until (PortMap.BASE_PORT + PortMap.RANGE),
                "port $port for $pkg out of range",
            )
        }
    }

    @Test
    fun derivationIsDeterministic() {
        // The agent and CLI compute this independently; they MUST agree, so the
        // same input always yields the same port across runs.
        assertEquals(
            PortMap.derivePort("dev.reticle.sample"),
            PortMap.derivePort("dev.reticle.sample"),
        )
    }

    @Test
    fun distinctPackagesGetDistinctPorts() {
        // Not guaranteed in general (hash range), but the two apps that collided
        // in practice must land on different ports — that's the whole point.
        assertNotEquals(
            PortMap.derivePort("dev.reticle.sample"),
            PortMap.derivePort("com.example.lender.debug"),
        )
    }

    @Test
    fun blankPackageFallsBackToBase() {
        assertEquals(PortMap.BASE_PORT, PortMap.derivePort(""))
        assertEquals(PortMap.BASE_PORT, PortMap.derivePort("   "))
    }

    @Test
    fun knownVectorsAreStable() {
        // Pin exact derived ports so an accidental algorithm change (which would
        // desync the agent and the CLI) fails loudly here instead of in the field.
        assertEquals(EXPECTED_SAMPLE_PORT, PortMap.derivePort("dev.reticle.sample"))
        assertEquals(EXPECTED_SECOND_PORT, PortMap.derivePort("com.example.lender.debug"))
    }

    private companion object {
        // Filled in from the reference implementation; see knownVectorsAreStable.
        const val EXPECTED_SAMPLE_PORT = 9763
        const val EXPECTED_SECOND_PORT = 9512
    }
}
