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

    override fun device(serial: String?): DeviceController = Adb(serial = serial)

    override fun input(device: DeviceController): InputDispatcher = InputBackend(device)

    override fun injector(): AppInjector = Injector
}
