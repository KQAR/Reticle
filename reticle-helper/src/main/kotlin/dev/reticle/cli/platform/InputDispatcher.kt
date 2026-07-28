package dev.reticle.cli.platform

/**
 * Synthesizes real user input on the device, backed by `adb shell input`;
 * `isAsciiTypeable` gates whether text can go through the native typing path or
 * must be staged via the agent clipboard. An internal seam of the Android
 * helper, like [DeviceController] — iOS synthesizes input in the Swift host
 * (CoreSimulator HID) and never reaches this code.
 */
interface InputDispatcher {
    fun tap(x: Int, y: Int): CommandResult
    fun swipe(x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Int = 300): CommandResult
    fun drag(x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Int = 1000): CommandResult
    /**
     * Type [value] into whatever holds focus. [perCharDelayMs] > 0 sends the
     * characters one at a time with that gap: the escape hatch for a field whose
     * `TextWatcher` reformats on every change and loses characters out of the
     * default single burst (see `TypeReadback`).
     */
    fun text(value: String, perCharDelayMs: Int = 0): CommandResult
    /** One or more key codes, dispatched in order in a single call. */
    fun keyevent(vararg keyCodes: String): CommandResult
    fun paste(): CommandResult
}
