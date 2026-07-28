package dev.reticle.cli

/**
 * Toasts an action raised, read from the system's own queue.
 *
 * The blind spot this closes: a tap the app answers with a `Toast`. Measured on
 * an API 36 emulator, four channels at once while one was on screen —
 *
 * | channel                          | text toast | custom-view toast |
 * |----------------------------------|------------|-------------------|
 * | the app's view tree              | absent     | **present**       |
 * | the agent's in-process screenshot| absent     | present           |
 * | `adb exec-out screencap`         | present    | present           |
 * | `dumpsys notification` Toast Queue | **text verbatim** | record, no text |
 *
 * — so a text toast is invisible to every channel Reticle had, and an action
 * answered by one read as `0 change(s)`: the documented signal for "the gesture
 * hit nothing". Two situations needing opposite responses, one reading.
 *
 * A text toast is not in the app's process at all on Android 11+: the app calls
 * `INotificationManager.enqueueToast`, and the system draws it in a window of its
 * own. What IS in the app's process, and therefore already in the tree, is a
 * custom-view toast (`Toast.setView`) and any app-drawn overlay — measured: both
 * appear as their own window node carrying the text. So the queue is not a
 * replacement for the tree; the two are complementary, and this file is the half
 * the tree structurally cannot answer.
 *
 * Host-side, over `adb shell`, so it needs no agent and works on the `noagent`
 * path. Nothing here is a hidden API: `dumpsys notification` is the notification
 * service printing its own state.
 */
internal object ToastQueue {

    /** The shell that costs ~25ms and returns nothing at all when no toast is up. */
    const val COMMAND = "dumpsys notification | grep ToastRecord"

    /** One toast the system had queued or on screen when a sample was taken. */
    data class Sighting(
        /** `text` — the system drew it; `custom-view` — the app's own view did. */
        val kind: String,
        val packageName: String,
        /** The record's binder token: unique per toast, so it is the dedup key. */
        val token: String?,
        /**
         * The message. Null for a custom-view toast **by construction**: that
         * record carries a callback into the app, not a string — the text is a
         * node in the view tree instead, and saying null here is what keeps the
         * two apart.
         */
        val text: String?,
        /** `short` (~2s) or `long` (~3.5s), from the record's duration flag. */
        val duration: String?,
        /** True for a toast the SYSTEM raised, not the app under test. */
        val isSystemToast: Boolean,
    ) {
        /** Same toast across two samples, or two different ones? */
        val identity: String get() = token ?: "$kind/$packageName/$text"
    }

    const val KIND_TEXT = "text"
    const val KIND_CUSTOM = "custom-view"

    /**
     * Parse the `ToastRecord` lines of a `dumpsys notification` dump, keeping only
     * toasts belonging to [packageName].
     *
     * The two record shapes, verbatim from an API 36 emulator:
     * ```
     * TextToastRecord{f933a23 16368:dev.reticle.sample/u0a214 isSystemToast=false
     *   token=android.os.BinderProxy@7789b20 text=rejected by server duration=1}
     * CustomToastRecord{cdd2539 16485:dev.reticle.sample/u0a214 isSystemToast=false
     *   token=android.os.BinderProxy@e96677e callback=android.app.ITransient…}
     * ```
     * `text=` runs to the `duration=` that closes the record, so the message is
     * read from the END rather than to the first space — a toast saying "duration
     * = 3 days" would otherwise be cut in half.
     */
    fun parse(dump: String, packageName: String): List<Sighting> {
        val out = ArrayList<Sighting>()
        for (raw in dump.lineSequence()) {
            val line = raw.trim()
            val kind = when {
                line.startsWith("TextToastRecord{") -> KIND_TEXT
                line.startsWith("CustomToastRecord{") -> KIND_CUSTOM
                else -> continue
            }
            val body = line.substringAfter('{').substringBeforeLast('}')
            val pkg = PACKAGE.find(body)?.groupValues?.get(1) ?: continue
            if (pkg != packageName) continue
            val durationFlag = body.substringAfterLast(" duration=", "").trim()
            val text = if (kind == KIND_TEXT) {
                body.substringAfter(" text=", "")
                    .substringBeforeLast(" duration=")
                    .takeIf { it.isNotEmpty() }
            } else {
                null
            }
            out += Sighting(
                kind = kind,
                packageName = pkg,
                token = TOKEN.find(body)?.groupValues?.get(1),
                text = text,
                duration = when (durationFlag) {
                    "0" -> "short"
                    "1" -> "long"
                    else -> null
                },
                isSystemToast = body.contains("isSystemToast=true"),
            )
        }
        return out
    }

    /**
     * The one line an act result carries. A custom-view toast has no text to
     * quote, so it says where the text IS rather than leaving the field empty —
     * "no message" and "the message is a node" are different facts.
     */
    fun summary(sighting: Sighting): String = sighting.text
        ?: "app-drawn custom view; its text is a node in the tree"

    private val PACKAGE = Regex("""\d+:([^/\s]+)/""")
    private val TOKEN = Regex("""token=(\S+)""")
}
