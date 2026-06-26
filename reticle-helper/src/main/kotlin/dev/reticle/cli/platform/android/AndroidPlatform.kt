package dev.reticle.cli.platform.android

import dev.reticle.cli.platform.AppInjector
import dev.reticle.cli.platform.DeviceController
import dev.reticle.cli.platform.InputDispatcher
import dev.reticle.cli.platform.Platform

/**
 * The Android implementation of the [Platform] SPI: device control over `adb`,
 * runtime injection over JDWP, and input via `adb shell input`.
 */
object AndroidPlatform : Platform {
    override val id: String = "android"

    // An explicit serial (from `--serial`) wins; otherwise fall back to
    // $ANDROID_SERIAL, the same variable plain `adb` honors — so a user who
    // already exports it to pick among several devices needs no extra flag.
    override fun device(serial: String?): DeviceController =
        Adb(serial = serial ?: System.getenv("ANDROID_SERIAL")?.ifBlank { null })

    override fun input(device: DeviceController): InputDispatcher = InputBackend(device)

    override fun injector(): AppInjector = Injector
}
