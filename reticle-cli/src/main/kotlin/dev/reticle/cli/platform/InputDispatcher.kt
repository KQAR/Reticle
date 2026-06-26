package dev.reticle.cli.platform

/**
 * Synthesizes real user input on the device. Android backs this with
 * `adb shell input`; `isAsciiTypeable` gates whether text can go through the
 * native typing path or must be staged via the agent clipboard.
 */
interface InputDispatcher {
    fun tap(x: Int, y: Int): CommandResult
    fun swipe(x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Int = 300): CommandResult
    fun drag(x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Int = 1000): CommandResult
    fun text(value: String): CommandResult
    fun keyevent(keyCode: String): CommandResult
    fun paste(): CommandResult
}
