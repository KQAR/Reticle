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

    override fun text(value: String): CommandResult {
        // `input text` treats spaces specially and chokes on some punctuation;
        // encode spaces as %s and escape shell-significant characters.
        val escaped = value
            .replace("\\", "\\\\")
            .replace(" ", "%s")
            .replace("'", "\\'")
            .replace("\"", "\\\"")
            .replace("(", "\\(")
            .replace(")", "\\)")
            .replace("&", "\\&")
        return adb.shell("input text \"$escaped\"")
    }

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
    }

    fun pinch(): Nothing =
        throw UnsupportedOperationException(
            "pinch is reserved but not implemented (needs sendevent multi-touch)"
        )
}
