package dev.reticle.cli

import dev.reticle.cli.platform.DeviceController
import dev.reticle.cli.platform.InputDispatcher
import dev.reticle.cli.platform.android.InputBackend
import dev.reticle.core.Node
import dev.reticle.core.SelectorResolver
import dev.reticle.core.SemanticTree
import dev.reticle.core.Snapshot
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * `act type`, `act hide-keyboard`, and everything typing needs to prove it worked.
 *
 * Split out of [HelperDeviceCommands], which had reached 1181 lines and eight
 * concerns. This is the Kotlin half of the same split the iOS backend just finished
 * — `IosTypeText.swift` is this file's twin, and the two already mirror each other
 * function for function (`refind`, the delete budget, the read-back), which is the
 * argument for cutting both at the same seam.
 *
 * It earns its own file by the test the Swift side uses: typing is the only command
 * here that has to re-find a node ACROSS two captures, because committing text
 * brings the IME's own views into the hierarchy and renumbers the tree. That
 * machinery — the read-back, the clear budget, the recovery of a partially-landed
 * burst — serves nothing else in the helper.
 *
 * Kotlin cannot spread one `object` over two files, so these are members of a new
 * object rather than an extension. `typeText` and `hideKeyboard` are `internal`
 * because [HelperDeviceCommands.act] dispatches to them; `liveSnapshot` stays there
 * and is called back into, since `domTapLanding` needs it too.
 */
internal object HelperTypeText {
    fun typeText(
        input: InputDispatcher,
        device: DeviceController,
        pkg: String,
        params: JsonObject,
    ): JsonObject {
        val text = params.str("text") ?: throw CliError("type needs 'text'")
        // If the caller named a target field, tap it first so the text lands in
        // THAT field. `input text` / paste both go to whatever currently holds
        // focus, so without this a `type --test-id foo` silently typed into the
        // wrong (or no) field. With no target, type into the current focus.
        var focus: ResolvedInputTarget? = null
        /** [focus]'s ref, re-resolved in whatever capture is being read. */
        var targetRef: String? = null
        var landing = TypeFocus.Landing.UNKNOWN
        var retargeted: String? = null
        // The tree as it stood the moment before the characters were dispatched:
        // one read, used for BOTH post-conditions — where focus went, and what the
        // field held before (the baseline the read-back is compared against).
        var before: Snapshot? = null
        if (hasInputTarget(params)) {
            focus = resolveInputTarget(device, pkg, params)
            input.tap(focus.point.x.toInt(), focus.point.y.toInt())
            Thread.sleep(FOCUS_SETTLE_MS)
            // Verify FOCUS, not just dispatch. A tap on a node that cannot take
            // focus — the outer container of a compound input widget, which is
            // often the only uniquely-addressable handle — leaves the text going
            // to whatever held focus before. See [TypeFocus].
            before = HelperDeviceCommands.liveSnapshot(device, pkg, params)
            // The ref the resolve produced belongs to the resolve's OWN capture, and
            // the focusing tap is exactly what invalidates it: a DOM re-render (the
            // page's focus/blur handlers, a keyboard-driven relayout) renumbers every
            // ref, and a ref is only a traversal index. Every read against `before`
            // therefore goes through the ref re-resolved IN `before`.
            //
            // Measured on a real form: `act type --label "<field>"` typed the text
            // into the right field and then reported
            // `textLanded=unreadable textReadback=unavailable:no-text-field-node`,
            // because the stale ref pointed at a `<label>` in the new numbering — a
            // false negative on the one check that exists to catch false positives.
            targetRef = targetRefIn(before, params, focus.ref)
            landing = focusLanding(before, targetRef)
            if (!TypeFocus.isLanded(landing)) {
                // One retarget, and only when it is not a guess: exactly one
                // focusable text input inside the node the caller named.
                val candidate = targetRef?.let { ref ->
                    before?.let { TypeFocus.soleFocusableInput(it, ref) }
                }
                if (candidate?.frame != null) {
                    input.tap(candidate.frame!!.centerX.toInt(), candidate.frame!!.centerY.toInt())
                    Thread.sleep(FOCUS_SETTLE_MS)
                    before = HelperDeviceCommands.liveSnapshot(device, pkg, params)
                    targetRef = targetRefIn(before, params, focus.ref)
                    landing = focusLanding(before, targetRef)
                    if (TypeFocus.isLanded(landing)) retargeted = candidate.ref
                }
                if (!TypeFocus.isLanded(landing)) {
                    throw CliError(TypeFocus.refusal(landing, focus, candidate))
                }
            }
        } else {
            before = HelperDeviceCommands.liveSnapshot(device, pkg, params)
        }
        var field = before?.let { TypeReadback.field(it, targetRef) }
        // `--clear`: empty the field BEFORE typing, and prove it is empty.
        //
        // This flag used to be accepted and do nothing at all, which is the worst
        // possible shape for it: measured on a device, `type --clear` into a field
        // that already held "test1" left "test1test1", and into a field already at
        // its `maxLength` it reported `textLanded=none` with no mention that the
        // clear had not happened. The caller believes the field holds exactly what
        // it typed, and it does not.
        var clearOutcome: ClearOutcome? = null
        if (params.bool("clear")) {
            val outcome = clearField(input, device, pkg, params, field)
            clearOutcome = outcome
            field = outcome.field ?: field
            if (!outcome.empty) {
                throw CliError(
                    "--clear did not empty the field (${outcome.describe()}), so typing now would " +
                        "APPEND to what is still there and report success — refusing. Clear it by " +
                        "hand (`act tap` the field, then the keyboard's own clear) or drop --clear " +
                        "if appending is what you meant"
                )
            }
        }
        // `--type-delay`: pace the burst for a field that cannot keep up with it.
        val typeDelayMs = params.intOrNull("typeDelayMs")?.coerceIn(0, 2000) ?: 0
        val via: String
        if (InputBackend.isAsciiTypeable(text)) {
            input.text(text, typeDelayMs)
            via = if (typeDelayMs > 0) "input text (paced ${typeDelayMs}ms/char)" else "input text"
        } else {
            val client = runtimeClientFor(device, pkg, params)
            assertHealthy(client, pkg)
            client.setClipboard(text)
            val pasted = input.paste()
            if (!pasted.ok) {
                throw CliError("staged text on clipboard but paste failed: ${pasted.stderr.ifBlank { "no focused input?" }}")
            }
            via = "clipboard paste"
        }
        // What reached the field, before anything else can move the screen —
        // `--submit` in particular clears or navigates away from it.
        val readback = readBackTypedText(input, device, pkg, params, before, targetRef, field, text, typeDelayMs)
        val submit = if (params.bool("submit")) submitAfterType(input, device, pkg, params) else null
        return buildJsonObject {
            put("gesture", "type"); put("chars", text.length)
            put("via", readback.via ?: via)
            readback.writeInto(this)
            clearOutcome?.let {
                put("cleared", it.summary)
                put("clearDetail", it.wire)
            }
            focus?.let {
                put("focusedVia", it.source)
                it.ref?.let { r -> put("ref", r) }
                // Where the focus actually went, not merely that a tap was
                // dispatched. `unknown` means no focus reading was available —
                // never a claim that it landed.
                put("focusLanded", TypeFocus.label(landing))
                retargeted?.let { r -> put("retargetedTo", r) }
            }
            submit?.let { put("submit", it) }
            keyboardVisibleAfterType(device, pkg, params)?.let { put("keyboardVisible", it) }
        }
    }

    /**
     * Trigger the focused field's submit after `type --submit`. Preferred path
     * is the in-app agent's editor action (TextView.onEditorAction — the exact
     * semantic of the keyboard's Done/Go key, and what React Native's
     * onSubmitEditing listens for); when the agent is unreachable, or answers
     * without a focused field, fall back to KEYCODE_ENTER, which single-line
     * fields translate into the same action.
     */
    private fun submitAfterType(
        input: InputDispatcher,
        device: DeviceController,
        pkg: String,
        params: JsonObject,
    ): JsonObject {
        // Let the field commit the just-typed text before dispatching the action.
        Thread.sleep(FOCUS_SETTLE_MS)
        val client = runtimeClientFor(device, pkg, params)
        if (client.probe() is RuntimeHealth.Healthy) {
            val result = runCatching { client.performEditorAction() }.getOrNull()
            if (result != null && result.performed) {
                return buildJsonObject {
                    put("via", "agent editorAction")
                    result.action?.let { put("action", it) }
                }
            }
        }
        val r = input.keyevent("KEYCODE_ENTER")
        if (!r.ok) {
            throw CliError("typed but submit failed: ${r.stderr.ifBlank { "adb shell did not complete" }}")
        }
        return buildJsonObject { put("via", "keyevent ENTER") }
    }

    /**
     * Opportunistic post-type keyboard probe. Typing almost always leaves the
     * IME up and covering the bottom of the screen — the classic next-step trap
     * is tapping a submit button that is now under the keyboard — so surface
     * that in the type result when the agent can tell us. Null (omitted) when
     * the runtime is unreachable; plain typing must not start failing over an
     * optional status field.
     */
    private fun keyboardVisibleAfterType(
        device: DeviceController,
        pkg: String,
        params: JsonObject,
    ): Boolean? = runCatching {
        val client = runtimeClientFor(device, pkg, params)
        if (client.probe() is RuntimeHealth.Healthy) client.keyboard().visible else null
    }.getOrNull()

    /**
     * Dismiss the system keyboard. Preferred path is the in-app agent's
     * InputMethodManager (deterministic, reports settled before/after state);
     * when the agent is unreachable we fall back to KEYCODE_ESCAPE — unlike
     * KEYCODE_BACK it does not navigate back when the keyboard is already gone.
     */
    fun hideKeyboard(
        input: InputDispatcher,
        device: DeviceController,
        pkg: String,
        params: JsonObject,
    ): JsonObject {
        val client = runtimeClientFor(device, pkg, params)
        if (client.probe() is RuntimeHealth.Healthy) {
            val result = client.hideKeyboard()
            return buildJsonObject {
                put("gesture", "hideKeyboard")
                put("via", "agent imm")
                put("wasVisible", result.wasVisible)
                put("keyboardVisible", result.keyboard.visible)
            }
        }
        val r = input.keyevent("KEYCODE_ESCAPE")
        if (!r.ok) {
            throw CliError("agent unreachable and keyevent fallback failed: ${r.stderr.ifBlank { "adb shell did not complete" }}")
        }
        return buildJsonObject {
            put("gesture", "hideKeyboard")
            put("via", "keyevent ESCAPE (agent unreachable; state unknown)")
        }
    }

    /**
     * Classify where focus went in [snapshot]. Best-effort by design: a runtime
     * that could not answer (a null snapshot) yields [TypeFocus.Landing.UNKNOWN],
     * and typing proceeds — an optional post-condition must not turn a working
     * `type` into a failure.
     */
    private fun focusLanding(snapshot: Snapshot?, targetRef: String?): TypeFocus.Landing =
        snapshot?.let { TypeFocus.classify(it, targetRef) } ?: TypeFocus.Landing.UNKNOWN

    /**
     * The caller's field as it is numbered in [snapshot] — the capture the focus
     * post-condition is read from, which is NOT the one the selector resolved in.
     *
     * A ref is the traversal index of a node in its own capture, so any relayout
     * renumbers it, and in a WebView any re-render does. The focusing tap can cause
     * one itself: scrolling the field into view, or the page inserting a validation
     * row above it. Comparing the fresh focus reading against the ref from the
     * previous capture then asks about whatever now sits at that index.
     *
     * Measured while driving a real hybrid form: three `type --css` calls in a row
     * were refused with `focus is on an unrelated node`, and a `ui compact` a moment
     * later showed the named field holding focus exactly as asked — every one of
     * them a false refusal, and each cost a retry that then succeeded unchanged.
     *
     * So re-resolve the SELECTOR against the new capture. A bare `--ref` or
     * `--point` has nothing to re-resolve, and a selector that no longer matches
     * anything keeps the original ref — for which `TARGET_GONE` is the honest
     * verdict rather than a claim about an unrelated node.
     */
    private fun targetRefIn(snapshot: Snapshot?, params: JsonObject, resolvedRef: String?): String? {
        if (snapshot == null) return resolvedRef
        val selector = selectorFrom(params)
        val reResolvable = selector.testId != null || selector.resourceId != null ||
            selector.cssSelector != null || selector.label != null || selector.region != null
        if (!reResolvable) return resolvedRef
        val again = runCatching {
            SelectorResolver(snapshot, SemanticTree.build(snapshot)).resolve(selector)
        }.getOrNull()
        return again?.ref ?: resolvedRef
    }

    /** The `type` post-condition: what the field holds now, and how it got there. */
    private class Readback(
        val landed: TypeReadback.Landed,
        val landedChars: Int = 0,
        val text: String? = null,
        val unavailable: String? = null,
        val recovery: String? = null,
        /** Overrides the dispatch `via=` when a recovery re-sent the text. */
        val via: String? = null,
        /**
         * Why nothing landed, when the field itself says why. Measured on a real
         * form: a field already at its `maxLength` reported `textLanded=none` and
         * nothing else, which reads as "the tool failed" rather than "the field is
         * full" — two opposite next actions (retry vs clear it first).
         */
        val landedReason: String? = null,
    ) {
        fun writeInto(builder: JsonObjectBuilder) {
            builder.put("textLanded", TypeReadback.label(landed))
            landedReason?.let { builder.put("textLandedReason", it) }
            text?.let { builder.put("text", it) }
            if (landed == TypeReadback.Landed.PARTIAL ||
                landed == TypeReadback.Landed.DROPPED
            ) {
                builder.put("landedChars", landedChars)
            }
            unavailable?.let { builder.put("textReadback", "unavailable:$it") }
            recovery?.let { builder.put("recovery", it) }
        }
    }

    /**
     * Read the field back after typing and say what is in it.
     *
     * `chars=N` counts what was SENT. The gap that costs a caller a whole form flow
     * is a field that took three of five characters and reported success: measured
     * on a physical device, `--text "10000"` left `100` in a field whose
     * `TextWatcher` reformats the value and re-renders a widget above it, while the
     * neighbouring field on the same screen took the same five characters intact.
     * See [TypeReadback] for the classification and why it is not a verdict.
     *
     * Best-effort, like every other optional post-condition here: an unreachable
     * runtime or a field with no text channel is reported as unavailable and
     * `type` still succeeds. It never claims a landing it did not read.
     */
    private fun readBackTypedText(
        input: InputDispatcher,
        device: DeviceController,
        pkg: String,
        params: JsonObject,
        before: Snapshot?,
        targetRef: String?,
        field: Node?,
        typed: String,
        typeDelayMs: Int,
    ): Readback {
        if (field == null) {
            return Readback(
                TypeReadback.Landed.UNREADABLE,
                unavailable = TypeReadback.whyUnreadable(before, targetRef),
            )
        }
        // A node that publishes no text before typing is read as empty rather than
        // as unreadable: an empty field is the overwhelmingly common case, and the
        // channel proves itself either way on the read AFTER typing.
        val had = TypeReadback.valueOf(field) ?: ""
        val after = settledFieldText(device, pkg, params, field, had)
            ?: return Readback(
                TypeReadback.Landed.UNREADABLE,
                unavailable = TypeReadback.Unavailable.GONE,
            )
        // A text field publishing no text reads as EMPTY, not as unreadable. The
        // agents emit a blank value as absent, so an empty input has no `text` at
        // all — and calling that "no text channel" turned the commonest state a
        // field can be in into a missing check. `field` has already established
        // that this node IS a text input; whether it holds anything is the answer,
        // not a reason to stop.
        val landedText = TypeReadback.valueOf(after) ?: ""
        val verdict = TypeReadback.classify(had, landedText, typed)
        if (!TypeReadback.isLoss(verdict.landed)) {
            return Readback(verdict.landed, verdict.landedChars, landedText)
        }
        // The field's own constraint, when it explains the loss: a field already at
        // its `maxLength` accepts nothing, and re-sending over the clipboard cannot
        // change that. Reported instead of retried.
        atMaxLength(after, landedText)?.let { reason ->
            return Readback(verdict.landed, verdict.landedChars, landedText, landedReason = reason)
        }
        return recoverLostText(input, device, pkg, params, after, had, typed, typeDelayMs, verdict)
    }

    /** What `--clear` did, and whether the field is provably empty afterwards. */
    private class ClearOutcome(
        val empty: Boolean,
        val before: String?,
        val after: String?,
        val deletes: Int,
        val unavailable: String?,
        val field: Node?,
    ) {
        fun describe(): String = when {
            unavailable != null -> "the field could not be read back: $unavailable"
            after == null -> "the field could not be read back"
            else -> "it still holds ${after.length} char(s)"
        }

        /**
         * One field, one token: the display line is `k=v` pairs, and a nested
         * object there renders as four lines of pretty-printed dictionary in the
         * middle of a result. The structured form lives in `clearDetail`.
         */
        val summary: String = when {
            empty && deletes == 0 -> "already-empty"
            empty -> "emptied(${deletes}ch)"
            unavailable != null -> "failed:$unavailable"
            else -> "failed:${after?.length ?: "?"}ch-left"
        }

        val wire: JsonObject = buildJsonObject {
            put("emptied", empty)
            put("deletes", deletes)
            before?.let { put("before", it) }
            after?.let { put("after", it) }
            unavailable?.let { put("unavailable", it) }
        }
    }

    /**
     * Empty the focused field, then read it back and say what happened.
     *
     * One DEL per character the field ACTUALLY holds, after moving the caret to the
     * end — deleting what is there rather than a fixed number is the difference
     * between clearing the field and eating the line above it (the same rule the
     * clipboard recovery path uses). A field longer than [MAX_RECOVERY_DELETES] is
     * not hammered with hundreds of key events: it is reported as not cleared, and
     * the caller decides.
     *
     * The read-back is the point. Without it this is another flag that claims work
     * it did not do; with it, the one thing `--clear` can never do again is leave
     * old content in place while the result reads like a clean write.
     */
    private fun clearField(
        input: InputDispatcher,
        device: DeviceController,
        pkg: String,
        params: JsonObject,
        field: Node?,
    ): ClearOutcome {
        if (field == null) {
            return ClearOutcome(
                empty = false, before = null, after = null, deletes = 0,
                unavailable = TypeReadback.Unavailable.NO_FIELD, field = null,
            )
        }
        val before = TypeReadback.valueOf(field)
            ?: return ClearOutcome(
                empty = false, before = null, after = null, deletes = 0,
                unavailable = TypeReadback.Unavailable.NO_TEXT_CHANNEL, field = field,
            )
        if (before.isEmpty()) {
            return ClearOutcome(true, before, before, 0, null, field)
        }
        if (before.length > MAX_RECOVERY_DELETES) {
            return ClearOutcome(
                empty = false, before = before, after = before, deletes = 0,
                unavailable = "field-too-long (${before.length} chars, limit $MAX_RECOVERY_DELETES)",
                field = field,
            )
        }
        input.keyevent("KEYCODE_MOVE_END")
        input.keyevent(*Array(before.length) { "KEYCODE_DEL" })
        // Poll, for the reason [settledFieldText] exists: a DOM input's value
        // arrives through the page's own handlers, so one read after a fixed sleep
        // catches it mid-flight. Measured on a masked postcode field — `--clear`
        // refused with "it still holds 6 char(s)" and a `ui compact` a moment later
        // showed the field EMPTY, so the refusal blocked a clear that had worked.
        val reread = emptiedFieldText(device, pkg, params, field)
        val after = reread?.let { TypeReadback.valueOf(it) }
        return ClearOutcome(
            empty = after != null && after.isEmpty(),
            before = before,
            after = after,
            deletes = before.length,
            unavailable = if (reread == null) TypeReadback.Unavailable.GONE else null,
            field = reread ?: field,
        )
    }

    /**
     * Re-send text the read-back proved did not fully land, once, over the
     * clipboard — which a `TextWatcher` sees as a single change rather than a
     * burst of keystrokes, so it cannot be cut in half the way the key path was.
     *
     * Narrow on purpose. It only fires when the field was EMPTY before typing, so
     * clearing it restores exactly the state that was there; with pre-existing
     * content, `type` inserts at the caret and there is no way to undo a partial
     * insertion without guessing what the caller meant to keep. It never fires for
     * [TypeReadback.Landed.CHANGED] (the app transforming its own input is not a
     * defect), never more than once, and never silently — the result says what it
     * did, and if the second attempt lands no better the honest classification of
     * that attempt is what gets reported.
     */
    /**
     * `at-maxLength(N)` when the field is full, else null.
     *
     * The check is `>=`, not `==`: a field whose limit was lowered after it was
     * prefilled holds more than it now accepts, and that is still the same answer.
     */
    private fun atMaxLength(field: Node, text: String): String? {
        val limit = field.maxLength() ?: return null
        if (limit <= 0 || text.length < limit) return null
        return "at-maxLength($limit)"
    }

    private fun recoverLostText(
        input: InputDispatcher,
        device: DeviceController,
        pkg: String,
        params: JsonObject,
        field: Node,
        before: String,
        typed: String,
        typeDelayMs: Int,
        first: TypeReadback.Verdict,
    ): Readback {
        val landedText = TypeReadback.valueOf(field).orEmpty()
        val recoverable = before.isEmpty() && typeDelayMs == 0 &&
            landedText.length <= MAX_RECOVERY_DELETES
        if (!recoverable) {
            return Readback(first.landed, first.landedChars, landedText)
        }
        val client = runCatching { runtimeClientFor(device, pkg, params) }.getOrNull()
        if (client == null || client.probe() !is RuntimeHealth.Healthy) {
            return Readback(
                first.landed, first.landedChars, landedText,
                recovery = "not attempted (clipboard needs the agent; it is unreachable)",
            )
        }
        val outcome = runCatching {
            // Caret to the end, then one DEL per character actually in the field:
            // deleting what landed, not what was asked for, is the difference
            // between clearing the field and eating the line above it.
            input.keyevent("KEYCODE_MOVE_END")
            if (landedText.isNotEmpty()) {
                input.keyevent(*Array(landedText.length) { "KEYCODE_DEL" })
            }
            client.setClipboard(typed)
            val pasted = input.paste()
            if (!pasted.ok) error("paste failed: ${pasted.stderr.ifBlank { "no focused input?" }}")
            Thread.sleep(READBACK_SETTLE_MS)
            readFieldText(device, pkg, params, field)
        }.getOrElse { error ->
            return Readback(
                first.landed, first.landedChars, landedText,
                recovery = "clipboard paste failed (${error.message}); the field holds what the keys left",
            )
        }
        val secondText = outcome?.let { TypeReadback.valueOf(it) }
            ?: return Readback(
                TypeReadback.Landed.UNREADABLE,
                unavailable = TypeReadback.Unavailable.GONE,
                recovery = "re-sent over the clipboard, then the field could not be read back",
            )
        val second = TypeReadback.classify("", secondText, typed)
        return Readback(
            second.landed, second.landedChars, secondText,
            recovery = "${TypeReadback.label(first.landed)} on the key path" +
                (if (first.landed == TypeReadback.Landed.PARTIAL) " (${first.landedChars}/${typed.length} chars)" else "") +
                "; re-sent over the clipboard",
            via = "clipboard paste (after input text ${TypeReadback.label(first.landed)})",
        )
    }

    private fun readFieldText(
        device: DeviceController,
        pkg: String,
        params: JsonObject,
        field: Node,
    ): Node? = HelperDeviceCommands.liveSnapshot(device, pkg, params)?.let { TypeReadback.refind(it, field) }

    /**
     * The field's text once it has stopped arriving — up to [READBACK_ATTEMPTS]
     * reads, returning as soon as the value differs from [had].
     *
     * One read after a fixed sleep is enough for a View, which is updated
     * synchronously by the key events. It is not enough for a DOM input: the
     * characters go in through the IME, the page's own handlers run, and the
     * traversal script reads whatever the DOM held at that instant — measured, a
     * field that ended up holding `00-001` read back empty on the first attempt.
     * Reporting that as "the field exposes no text" would be a false negative on
     * the very check that exists to catch false positives, and it would send the
     * clipboard recovery in to re-type text that had in fact landed.
     *
     * Bounded, and it never waits for a value it wants: a field that genuinely did
     * not change costs the full budget and is then classified as such, which is the
     * honest reading of "nothing arrived".
     */
    /**
     * The field's text once the deletes have finished — up to
     * [CLEAR_READBACK_ATTEMPTS] reads, returning as soon as it is EMPTY.
     *
     * Waiting for "empty" rather than for "changed" is the whole point. A masked
     * DOM input rewrites its value on every delete, so a read that waits for any
     * change returns on the first INTERMEDIATE value and `--clear` then refuses
     * with "it still holds N char(s)" for a clear that was working. Measured on
     * three separate fields of a real form — refusals citing 6, 9 and 18
     * characters, with a screenshot a moment later showing every one of them
     * empty. The budget is only spent when the field is not empty yet, so a field
     * that genuinely refuses to clear is still reported as such.
     */
    private fun emptiedFieldText(
        device: DeviceController,
        pkg: String,
        params: JsonObject,
        field: Node,
    ): Node? {
        var last: Node? = null
        repeat(CLEAR_READBACK_ATTEMPTS) {
            Thread.sleep(READBACK_SETTLE_MS)
            val node = readFieldText(device, pkg, params, field) ?: return last
            last = node
            if ((TypeReadback.valueOf(node) ?: "").isEmpty()) return node
        }
        return last
    }

    private fun settledFieldText(
        device: DeviceController,
        pkg: String,
        params: JsonObject,
        field: Node,
        had: String,
    ): Node? {
        var last: Node? = null
        repeat(READBACK_ATTEMPTS) {
            Thread.sleep(READBACK_SETTLE_MS)
            val node = readFieldText(device, pkg, params, field) ?: return last
            last = node
            if ((TypeReadback.valueOf(node) ?: "") != had) return node
        }
        return last
    }

    /** Whether the caller supplied any field-targeting selector for `type`. */
    private fun hasInputTarget(params: JsonObject): Boolean =
        SELECTOR_KEYS.any { params.str(it) != null }

    /** Params [resolveInputTarget]/[selectorFrom] read as a targeting selector. */
    /**
     * Every selector `type` will TAP before dispatching text. A selector missing
     * from this list is not rejected — it is silently ignored, and the text goes to
     * whatever already held focus while the result still names the selector.
     *
     * `label` was missing, which is the worst place for it to be missing: a control
     * with no id and no visible text of its own — a checkbox, an aria-labelled input
     * on a component-framework form — has `--label` as its ONLY documented handle,
     * so `act type --label "Postcode"` typed into the previous field and reported
     * success. Measured on the web form fixture.
     */
    private val SELECTOR_KEYS = listOf(
        "alias", "point", "testId", "resourceId", "css", "cssSelector", "ref", "region", "label",
    )

    /** Time for a tapped field to take focus before we dispatch text. */
    private const val FOCUS_SETTLE_MS = 200L

    /**
     * Time for the typed text to reach the field before reading it back. The
     * failure this check exists for is a field that re-lays-out on every keystroke,
     * so the read must sit behind that work rather than race it.
     */
    private const val READBACK_SETTLE_MS = 250L

    /**
     * How many times [settledFieldText] re-reads before taking the field's text as
     * final. Three at 250ms is ~750ms worst case, paid only by a `type` whose field
     * really did not change — the case that was already going to be reported as a
     * loss.
     */
    private const val READBACK_ATTEMPTS = 3

    /**
     * How many times `--clear` re-reads the field before believing it is not empty.
     * Higher than [READBACK_ATTEMPTS] because the condition is stricter: a masked
     * input passes through several intermediate values on its way to empty, and
     * only the last one is the answer.
     */
    private const val CLEAR_READBACK_ATTEMPTS = 6

    /**
     * A field longer than this is not cleared for a recovery attempt. One DEL per
     * character is real input, and a long field would mean a long burst of it —
     * exactly the shape of dispatch this whole check distrusts.
     */
    private const val MAX_RECOVERY_DELETES = 64
}
