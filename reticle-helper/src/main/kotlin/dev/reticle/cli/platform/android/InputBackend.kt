package dev.reticle.cli.platform.android

import dev.reticle.cli.platform.CommandResult
import dev.reticle.cli.platform.DeviceController
import dev.reticle.cli.platform.InputDispatcher

/**
 * Android [InputDispatcher]: real on-device input via the public `adb shell input`
 * tool. tap / swipe / text / keyevent all map directly to `input` subcommands; a
 * drag is a long-duration swipe.
 *
 * (Multi-touch pinch is the one gesture `input` can't express; it would need
 * `sendevent` against the touchscreen device node. It is reserved but
 * unimplemented; the API shape is sketched below.)
 */
class InputBackend(private val adb: DeviceController) : InputDispatcher {

    override fun tap(x: Int, y: Int): CommandResult =
        adb.shell("input tap $x $y")

    override fun swipe(x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Int): CommandResult =
        adb.shell("input swipe $x1 $y1 $x2 $y2 $durationMs")

    /** A drag is a slow swipe; longer default duration so views register a drag. */
    override fun drag(x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Int): CommandResult =
        adb.shell("input swipe $x1 $y1 $x2 $y2 $durationMs")

    override fun text(value: String): CommandResult =
        adb.shell("input text ${shellArgForInputText(value)}")

    override fun keyevent(keyCode: String): CommandResult =
        adb.shell("input keyevent $keyCode")

    /** Paste the device clipboard into the focused field (KEYCODE_PASTE = 279). */
    override fun paste(): CommandResult = keyevent("279")

    companion object {
        /**
         * `adb shell input text` can only emit ASCII; anything outside it (CJK,
         * accented Latin, emoji, …) is silently dropped. Callers route non-ASCII
         * through the agent clipboard + paste path instead.
         */
        fun isAsciiTypeable(text: String): Boolean = text.all { it.code in 0x20..0x7E }

        /**
         * Build the shell argument for `adb shell input text`. Two independent
         * layers:
         *
         *  1. `input text` semantics: a literal space separates arguments, so
         *     spaces are encoded as `%s` (the tool decodes them back to spaces).
         *  2. Shell safety: the payload is wrapped in single quotes so the device
         *     shell interprets nothing — `$`, backticks, `(`, `)`, `&`, `\`, `"`
         *     are passed through literally rather than expanded or executed. This
         *     closes the injection the previous double-quote wrapping left open
         *     (`$(…)` / backticks in typed text ran on device). A literal single
         *     quote is emitted with the POSIX `'\''` idiom.
         *
         * Gated by [isAsciiTypeable]; non-ASCII goes through the clipboard path.
         */
        fun shellArgForInputText(value: String): String {
            val spaceEncoded = value.replace(" ", "%s")
            val quoted = spaceEncoded.replace("'", "'\\''")
            return "'$quoted'"
        }
    }

    fun pinch(): Nothing =
        throw UnsupportedOperationException(
            "pinch is reserved but not implemented (needs sendevent multi-touch)"
        )
}
