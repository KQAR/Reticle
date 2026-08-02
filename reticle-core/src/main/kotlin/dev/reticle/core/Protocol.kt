package dev.reticle.core

import kotlinx.serialization.Serializable

/**
 * Wire protocol shared by the in-app server and the host CLI: a small set of
 * localhost endpoints (/runtime, /report, /snapshot, /semantics, /logs).
 *
 * Endpoint map (HTTP GET unless noted), all bound to 127.0.0.1 in-app and
 * reached through `adb forward`:
 *
 *   GET  /runtime         -> RuntimeInfo
 *   GET  /report          -> UiReport
 *   GET  /snapshot        -> Snapshot
 *   GET  /semantics       -> SemanticTree
 *   GET  /compact         -> CompactObservation
 *   GET  /logs            -> LogBatch
 *   GET  /screenshot      -> image/png bytes
 *   GET  /keyboard        -> KeyboardInfo
 *   POST /keyboard/hide   -> KeyboardHideResult (no body)
 *   POST /editor-action   -> EditorActionResult (no body)
 *   POST /mutate          -> MutationResult   (body: MutationRequest)
 *   POST /clipboard       -> "ok"             (body: raw UTF-8 text)
 *
 * The Swift `Endpoints` in reticle-swift mirrors this list, with two
 * deliberate asymmetries where the platform affordance exists on one side
 * only:
 *
 * - `/editor-action` ([EDITOR_ACTION]) is Android-only; UIKit has no
 *   equivalent "perform the return key's action" entry point, so `act type
 *   --submit` on iOS goes through the HID return key.
 * - `/activate` is iOS-only (`Endpoints.activate` on the Swift side, absent
 *   here): it exists because host-side HID synthesis cannot reach a real iOS
 *   device, which is not a problem Android has.
 *
 * Anything else in either list without a twin is drift, not design.
 */
object Endpoints {
    const val RUNTIME = "/runtime"
    const val REPORT = "/report"
    const val SNAPSHOT = "/snapshot"
    const val SEMANTICS = "/semantics"
    const val COMPACT = "/compact"
    const val LOGS = "/logs"
    const val SCREENSHOT = "/screenshot"
    const val MUTATE = "/mutate"

    /**
     * Set the device clipboard from inside the app process (body is the raw
     * UTF-8 text). This is the reliable way to stage non-ASCII input: `adb shell
     * input text` cannot emit non-ASCII at all, host-side `adb shell cmd
     * clipboard` is absent on many OEM builds, and Android 10+ blocks clipboard
     * writes from any process that isn't the foreground app — which the agent,
     * running inside that app, is. The CLI follows this with a KEYCODE_PASTE.
     */
    const val CLIPBOARD = "/clipboard"

    /** Current system-keyboard (IME) state, probed from inside the app. */
    const val KEYBOARD = "/keyboard"

    /**
     * Dismiss the system keyboard from inside the app process via
     * InputMethodManager — deterministic, unlike a host-side KEYCODE_BACK
     * (which navigates back when the keyboard is already gone). Answers with
     * the settled post-hide state.
     */
    const val KEYBOARD_HIDE = "/keyboard/hide"

    /**
     * Android-only (no iOS counterpart — see the object doc).
     *
     * Perform the focused field's IME editor action (the keyboard's Done /
     * Next / Go / Search / Send key) from inside the app process. This is what
     * `act type --submit` prefers: TextView.onEditorAction() drives the app's
     * OnEditorActionListener (React Native's onSubmitEditing included)
     * deterministically, where a host-side KEYCODE_ENTER inserts a newline
     * into multiline fields and is dropped by some IMEs. Answers with the
     * settled post-action keyboard state.
     */
    const val EDITOR_ACTION = "/editor-action"
}

/** Identifies the running app process behind the loopback server. */
@Serializable
data class RuntimeInfo(
    val packageName: String,
    val processName: String,
    val pid: Int,
    val sdkInt: Int,
    val agentVersion: String,
    val port: Int,
)

@Serializable
data class LogEntry(
    val timestampMillis: Long,
    val level: String,
    val message: String,
    val metadata: Map<String, MetadataValue> = emptyMap(),
)

@Serializable
data class LogBatch(val entries: List<LogEntry>)

/**
 * A single-capture UI report produced inside the app process.
 *
 * The full snapshot is captured once, then the semantic tree and compact
 * observation are derived from that exact frame so report files cannot drift.
 */
@Serializable
data class UiReport(
    val snapshot: Snapshot,
    val semantics: SemanticTree,
    val compact: CompactObservation,
) {
    companion object {
        /** Build all report views from one authoritative snapshot. */
        fun from(snapshot: Snapshot): UiReport = UiReport(
            snapshot = snapshot,
            semantics = SemanticTree.build(snapshot),
            compact = CompactObservation.from(snapshot),
        )
    }
}

/** Answer of [Endpoints.KEYBOARD_HIDE]: what was on screen, and what is now. */
@Serializable
data class KeyboardHideResult(
    val wasVisible: Boolean,
    val keyboard: KeyboardInfo,
)

/**
 * Answer of [Endpoints.EDITOR_ACTION]: whether a focused text field performed
 * its IME action, which action it was ("done"/"next"/"go"/"search"/"send"),
 * and the settled keyboard state afterwards.
 */
@Serializable
data class EditorActionResult(
    val performed: Boolean,
    val action: String? = null,
    val keyboard: KeyboardInfo? = null,
    val message: String? = null,
)

/**
 * Runtime property mutation. Allowlisted: only a bounded set of View properties
 * may be patched live so UI diagnosis and design iteration can happen without
 * rebuilding.
 */
@Serializable
data class MutationRequest(
    val selector: Selector,
    val property: String, // e.g. "alpha", "visibility", "text", "backgroundColor"
    val value: MetadataValue,
)

@Serializable
data class MutationResult(
    val applied: Boolean,
    val ref: String? = null,
    val previousValue: MetadataValue? = null,
    val message: String? = null,
)

/**
 * A stable target for actions and mutations. Resolution order: testId /
 * resource-id first (semantic-tree-backed), then ref, then raw point.
 */
@Serializable
data class Selector(
    val testId: String? = null,
    val resourceId: String? = null,
    /** CSS selector for DOM nodes captured from an embedded WebView. */
    val cssSelector: String? = null,
    val ref: String? = null,
    val point: Point? = null,
    /**
     * Visible text or a11y label, for controls the framework builds without any
     * stable id: a `Spinner` dropdown's rows, a `PopupMenu`'s items, an alert's
     * buttons. Those are captured but carry only a SHARED resource id (`text1`,
     * `title`), so nothing else can single one out. Matching is exact first, then
     * substring, and AMBIGUITY IS AN ERROR — never a silent first-match, which is
     * the failure mode that makes a wrong tap look like a working one.
     */
    val label: String? = null,
    /**
     * A substring/region within a node. Combined with a node selector
     * (testId/resourceId/ref) it targets a span/virtual-node/char-range inside
     * that node — e.g. tap just the 《agreement》 link inside a checkbox row.
     */
    val region: String? = null,
) {
    fun describe(): String = buildString {
        append(
            testId?.let { "testId=$it" }
                ?: resourceId?.let { "resourceId=$it" }
                ?: cssSelector?.let { "css=$it" }
                ?: ref?.let { "ref=$it" }
                ?: point?.let { "point=${it.x},${it.y}" }
                ?: label?.let { "label=$it" }
                ?: "<empty>"
        )
        region?.let { append(" region=\"$it\"") }
    }
}
