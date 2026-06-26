package dev.reticle.cli

import kotlin.system.exitProcess

/** Version, kept in lockstep with the agent and plugin manifest. */
const val RETICLE_VERSION = "0.4.0"

/**
 * Entry point for the **Android helper** behind the Swift host (`reticle-host`).
 *
 * This module is no longer a user-facing CLI. It compiles (via GraalVM
 * native-image) into the no-JDK `reticle-helper` binary, whose one job is to run
 * the long-lived JSONL RPC server (`helper`) that the Swift host drives across a
 * process boundary. See `reticle-protocol/helper-rpc.md` and the roadmap's
 * "Direction: Swift host + per-platform helpers".
 *
 * The device-driving and rendering logic lives in [Helper] (which reuses the
 * `platform/` SPI, [RuntimeClient], and [SelectorResolver]); the user-facing
 * command surface is the Swift host's, not this binary's.
 */
fun main(rawArgs: Array<String>) {
    val command = rawArgs.firstOrNull()
    try {
        when (command) {
            "helper" -> Helper.serve()
            "version", "--version", "-v" -> println("reticle-helper $RETICLE_VERSION")
            "help", "--help", "-h", null -> printUsage()
            else -> {
                System.err.println(
                    "reticle-helper: unknown command '$command'.\n" +
                        "  This binary is the Android helper for the Swift host (reticle-host) — it is\n" +
                        "  not a user-facing CLI. Use `reticle-host`; the `reticle` launcher drives it.\n" +
                        "  This binary only serves: helper | version | help."
                )
                exitProcess(2)
            }
        }
    } catch (e: CliError) {
        System.err.println("error: ${e.message}")
        exitProcess(1)
    }
}

private fun printUsage() {
    println(
        """
        reticle-helper — the Android helper behind the Swift host (reticle-host)

        helper      long-lived JSONL stdio RPC server (what reticle-host drives)
        version
        help

        This is not a user-facing CLI. Use `reticle-host` (the `reticle` launcher
        on PATH drives it). RPC contract: reticle-protocol/helper-rpc.md
        """.trimIndent()
    )
}

/** A user-actionable error with a clean message (no stack trace). */
class CliError(message: String) : RuntimeException(message)
