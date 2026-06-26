package dev.reticle.cli.platform

/**
 * Platform SPI — the thin reservation for multi-platform support.
 *
 * Reticle's host CLI is platform-neutral except for three seams: controlling the
 * device + transport, injecting the runtime, and synthesizing input. Those are
 * the interfaces below; everything else in the CLI (selector resolution, the
 * loopback HTTP client, the command surface) is shared.
 *
 * Today there is exactly ONE implementation, [dev.reticle.cli.platform.android].
 * These interfaces are therefore *extracted from* that one implementation rather
 * than designed against several — they are deliberately Android-shaped today
 * (e.g. [DeviceController] still exposes `shell`/`run`). When a second platform
 * (iOS / HarmonyOS) lands, the interfaces get refined against two real
 * implementations; until then this is a reservation, not a finished abstraction.
 * No empty stubs for absent platforms — interfaces, not stubs.
 */
interface Platform {
    /** Stable id, e.g. "android". Used by [Platforms.current] selection. */
    val id: String

    /** A controller bound to [serial] (or the sole device when null). */
    fun device(serial: String?): DeviceController

    /** Input synthesizer for [device]. */
    fun input(device: DeviceController): InputDispatcher

    /** The runtime injector for the unlinked (debuggable, no-AAR) path. */
    fun injector(): AppInjector
}

/** Result of a host->device command: exit code + captured streams. */
data class CommandResult(val exitCode: Int, val stdout: String, val stderr: String) {
    val ok: Boolean get() = exitCode == 0
}

/** An attached device and its raw readiness state ("device"/"offline"/...). */
data class DeviceState(val serial: String, val state: String)

/** A device-readiness problem (offline / unauthorized / absent), with guidance. */
class DeviceError(message: String) : RuntimeException(message)
