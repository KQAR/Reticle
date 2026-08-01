package dev.reticle.cli

import dev.reticle.cli.platform.DeviceController
import dev.reticle.cli.platform.InputDispatcher
import dev.reticle.cli.platform.android.Adb
import dev.reticle.cli.platform.android.Injector
import dev.reticle.cli.platform.android.InputBackend
import dev.reticle.core.CompactObservation
import dev.reticle.core.MutationRequest
import dev.reticle.core.Node
import dev.reticle.core.ReticleJson
import dev.reticle.core.SemanticTree
import dev.reticle.core.Snapshot
import java.util.Base64
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Device/runtime-backed helper RPC commands. */
internal object HelperDeviceCommands {
    fun listDevices(): JsonElement {
        val states = Adb.forSerial(null).listDeviceStates()
        return buildJsonObject {
            put("devices", buildJsonArray {
                states.forEach { s ->
                    add(buildJsonObject {
                        put("serial", s.serial)
                        put("state", s.state)
                    })
                }
            })
        }
    }

    fun status(params: JsonObject): JsonElement {
        val pkg = params.str("package")
        val device = Adb.forSerial(params.str("serial"))
        val states = device.listDeviceStates()
        return buildJsonObject {
            put("devices", buildJsonArray {
                states.forEach { s -> add(buildJsonObject { put("serial", s.serial); put("state", s.state) }) }
            })
            if (pkg != null) {
                device.ensureDeviceReady()
                val pid = device.pidOf(pkg)
                put("package", pkg)
                put("running", pid != null)
                if (pid != null) put("pid", pid)
                val client = runtimeClientFor(device, pkg, params)
                put("runtime", when (val h = client.probe()) {
                    is RuntimeHealth.Healthy -> if (h.info.packageName == pkg) "healthy" else "conflict"
                    is RuntimeHealth.Unreachable -> "unreachable"
                    is RuntimeHealth.Unresponsive -> "unresponsive"
                    is RuntimeHealth.Foreign -> "foreign"
                })
            }
        }
    }

    fun inject(params: JsonObject): JsonElement {
        val pkg = params.str("package") ?: throw CliError("inject needs 'package'")
        params.str("payloadDex")?.let { System.setProperty("reticle.payloadDex", it) }
        val device = Adb.forSerial(params.str("serial"))
        device.ensureDeviceReady()
        val injected = Injector.inject(device, pkg, restartUnderDebugger = params.bool("restartUnderDebugger"))
        val info = awaitRuntime(runtimeClientFor(device, pkg, params), pkg)
        return buildJsonObject {
            put("pid", info.pid)
            put("packageName", info.packageName)
            put("port", info.port)
            put("agentVersion", info.agentVersion)
            put("reportedPort", injected.reportedPort)
        }
    }

    fun uiReport(params: JsonObject): JsonElement {
        val pkg = params.str("package") ?: throw CliError("uiReport needs 'package'")
        val device = Adb.forSerial(params.str("serial"))
        device.ensureDeviceReady()
        val client = runtimeClientFor(device, pkg, params)
        assertHealthy(client, pkg)
        val report = client.report()
        return reportJson(report.snapshot, report.semantics, report.compact)
    }

    fun launch(params: JsonObject): JsonElement {
        val pkg = params.str("package") ?: throw CliError("launch needs 'package'")
        val device = Adb.forSerial(params.str("serial"))
        device.ensureDeviceReady()
        var r = device.shell("monkey -p $pkg -c android.intent.category.LAUNCHER 1")
        if (!r.ok) {
            Thread.sleep(500)
            r = device.shell("monkey -p $pkg -c android.intent.category.LAUNCHER 1")
        }
        if (!r.ok) throw CliError("failed to launch $pkg: ${r.stderr.ifBlank { "adb shell did not complete" }}")
        val info = awaitRuntime(runtimeClientFor(device, pkg, params), pkg)
        return buildJsonObject {
            put("pid", info.pid)
            put("packageName", info.packageName)
            put("port", info.port)
            put("agentVersion", info.agentVersion)
        }
    }

    fun act(params: JsonObject): JsonElement {
        val sub = params.str("gesture") ?: throw CliError("act needs 'gesture'")
        val pkg = params.str("package") ?: throw CliError("act needs 'package'")
        val device = Adb.forSerial(params.str("serial"))
        device.ensureDeviceReady()
        val input = InputBackend(device)

        val verifySel = HelperVerify.watchSelectorFrom(params)
        val traceRequested = params.str("traceOutput") != null
        val traceAuto = params.bool("traceAuto")
        val evidenceClient = if (verifySel != null || traceRequested) {
            runCatching { runtimeClientFor(device, pkg, params).also { c -> assertHealthy(c, pkg) } }
                .getOrElse { error ->
                    if (traceAuto && verifySel == null) null else throw error
                }
        } else {
            null
        }
        val traceRecorder = if (traceAuto && evidenceClient == null) {
            null
        } else {
            HelperActionTrace.from(params, pkg, evidenceClient)
        }
        val traceBefore = traceRecorder?.capture()
        val before = verifySel?.let { HelperVerify.captureState(evidenceClient!!, it) }
        var target: ResolvedInputTarget? = null

        // Watch the system Toast Queue across the action. A text toast is in no
        // window of this app, so an action answered by one produced a byte-identical
        // before/after pair — `0 change(s)`, the documented signal for a gesture that
        // hit nothing. `wait` is excluded because it dispatches no input: a toast
        // during a wait is not that command's answer. See [ToastProbe].
        val toastProbe = ToastProbe.start(
            device, pkg,
            enabled = sub != "wait" && !params.bool("noToastProbe"),
        )

        val result: JsonObject = when (sub) {
            "tap" -> {
                val first = resolveInputTarget(device, pkg, params)
                target = first
                // Confirm the resolved point has stopped moving BEFORE dispatching.
                //
                // Resolution and dispatch are two steps, and between them the screen
                // can move — not only because the target itself is animating in (the
                // popup case `--settle` was introduced for) but because a PREVIOUS
                // command relayouted the page: a `type` that showed the keyboard, a
                // `hide-keyboard` that took it away, a scroll. Measured on a physical
                // device: a form row tapped by its unique test id resolved to a rect
                // already 161px stale and opened the sheet belonging to the row below
                // it, reporting an unqualified success. Nothing in the result said so,
                // and the trace diff is equally large for the right sheet and the
                // wrong one.
                //
                // So the confirm is now the DEFAULT for selector-based taps rather
                // than opt-in: it costs one extra tree read against a resolution that
                // had to happen anyway, and the failure it prevents is silent and
                // expensive to detect. `--settle` keeps its meaning — give it the full
                // budget, for a target known to be animating — and `--no-settle` opts
                // out for a caller who wants the single-read dispatch.
                var stable: Boolean? = null
                val rawPoint = params.str("point") != null
                if (params.bool("settle") && rawPoint) {
                    throw CliError(
                        "--settle needs a selector: a raw --point has nothing to re-resolve, " +
                            "so there is no way to tell whether it has stopped moving"
                    )
                }
                val plan = TapSettlePolicy.plan(
                    rawPoint = rawPoint,
                    settle = params.bool("settle"),
                    noSettle = params.bool("noSettle"),
                    timeoutMs = params.intOrNull("settleTimeoutMs"),
                )
                if (plan.confirm) {
                    val settled = settleInputTarget(device, pkg, params, first = first, budgetMs = plan.budgetMs)
                    target = settled.target
                    stable = settled.stable
                }
                val x = target!!.point.x.toInt()
                val y = target!!.point.y.toInt()
                input.tap(x, y)
                buildJsonObject {
                    put("gesture", "tap")
                    put("x", x)
                    put("y", y)
                    put("source", target!!.source)
                    target!!.ref?.let { put("ref", it) }
                    // Honest flag, as in scroll-to: false means the target was still
                    // moving when the budget lapsed, so this tap may have been aimed
                    // at a point that had already changed.
                    stable?.let { put("settled", it) }
                    // The evidence that the first read WAS stale: the same selector,
                    // same ref, different coordinates. Without this the confirm would
                    // silently fix the tap and the caller would never learn that the
                    // screen it reasoned about had moved under it.
                    TapSettlePolicy.movedBy(first.point, target!!.point)?.let { put("rectMoved", it) }
                }
            }
            "swipe", "drag" -> {
                val (fx, fy) = parseXY(params.str("from") ?: throw CliError("$sub needs 'from'"))
                val (tx, ty) = parseXY(params.str("to") ?: throw CliError("$sub needs 'to'"))
                val dur = params.intOrNull("duration") ?: if (sub == "drag") 1000 else 300
                if (sub == "drag") input.drag(fx, fy, tx, ty, dur) else input.swipe(fx, fy, tx, ty, dur)
                buildJsonObject { put("gesture", sub); put("from", "$fx,$fy"); put("to", "$tx,$ty"); put("durationMs", dur) }
            }
            "scrollTo", "scroll-to" -> HelperScrollTo.run(input, device, pkg, params)
            "type" -> typeText(input, device, pkg, params)
            "hideKeyboard", "hide-keyboard" -> hideKeyboard(input, device, pkg, params)
            // The one gesture that dispatches no input: it only observes. Kept
            // under `act` because it is part of an action sequence (act, then wait
            // for the consequence) and shares the selector/trace surface.
            "wait" -> HelperWait.run(device, pkg, params)
            else -> throw CliError(
                "unknown act gesture '$sub' (tap/swipe/drag/scroll-to/type/hide-keyboard/wait)"
            )
        }

        val verify = verifySel?.let { HelperVerify.pollForChange(evidenceClient!!, it, before, params) }
        // Collected before the trace is written so the toast is IN the manifest for
        // that step — the place a later `trace log` reads, and the whole point: the
        // step that says "no observable change" must be the step that also says the
        // app answered out of tree.
        val toasts = toastProbe?.stop().orEmpty()
        val withToast = if (toasts.isEmpty()) result else buildJsonObject {
            result.forEach { (k, v) -> put(k, v) }
            val first = toasts.first()
            put("toast", ToastQueue.summary(first))
            put("toastKind", first.kind)
            first.duration?.let { put("toastDuration", it) }
            if (toasts.size > 1) put("toastCount", toasts.size)
        }
        val trace = traceRecorder?.let {
            val settleMs = if (verify == null) (params.intOrNull("traceDelayMs") ?: 250).toLong() else 0L
            it.write(sub, selectorOrNull(params), target, withToast, traceBefore!!, settleMs)
        }
        if (verify == null && trace == null) return withToast
        return buildJsonObject {
            withToast.forEach { (k, v) -> put(k, v) }
            verify?.let { put("verify", it) }
            trace?.let { put("trace", it) }
        }
    }

    fun mutate(params: JsonObject): JsonElement {
        val pkg = params.str("package") ?: throw CliError("mutate needs 'package'")
        val property = params.str("property") ?: throw CliError("mutate needs 'property'")
        val rawValue = params.str("value") ?: throw CliError("mutate needs 'value'")
        val device = Adb.forSerial(params.str("serial"))
        device.ensureDeviceReady()
        val client = runtimeClientFor(device, pkg, params)
        assertHealthy(client, pkg)
        val result = client.mutate(MutationRequest(selectorFrom(params), property, parseValue(rawValue)))
        if (!result.applied) throw CliError(result.message ?: "mutation failed")
        return buildJsonObject {
            put("applied", true)
            put("ref", result.ref)
            put("previousValue", result.previousValue?.displayString())
        }
    }

    fun logs(params: JsonObject): JsonElement {
        val pkg = params.str("package") ?: throw CliError("logs needs 'package'")
        val device = Adb.forSerial(params.str("serial"))
        device.ensureDeviceReady()
        val client = runtimeClientFor(device, pkg, params)
        assertHealthy(client, pkg)
        return buildJsonObject {
            put("entries", buildJsonArray {
                client.logs().entries.forEach { e ->
                    add(buildJsonObject { put("level", e.level); put("message", e.message) })
                }
            })
        }
    }

    fun logcat(params: JsonObject): JsonElement {
        val lines = Adb.forSerial(params.str("serial")).agentLog()
        return buildJsonObject {
            put("lines", buildJsonArray { lines.forEach { add(it) } })
        }
    }

    fun screenshot(params: JsonObject): JsonElement {
        val pkg = params.str("package")
        val device = Adb.forSerial(params.str("serial"))
        device.ensureDeviceReady()
        var via = "adb screencap"
        // One client and one probe serve both the capture attempt and the
        // degrade notes below; building a second client for the notes used to
        // pay a second `adb forward` fork and a second probe in the same RPC.
        val client = pkg?.let { runtimeClientFor(device, it, params) }
        val agentUp = client != null && client.probe() is RuntimeHealth.Healthy
        val agentBytes = if (agentUp) {
            captureAgentScreenshot(client!!)?.also { via = "agent /screenshot" }
        } else {
            null
        }
        val bytes = agentBytes ?: device.screencap().also {
            if (it.isEmpty()) throw CliError("screencap returned no data (device ready?)")
        }
        return buildJsonObject {
            put("via", via)
            put("pngBase64", Base64.getEncoder().encodeToString(bytes))
            val degraded = if (agentUp) screenshotDegrades(client!!, viaAgent = agentBytes != null) else null
            if (!degraded.isNullOrEmpty()) {
                put("degraded", buildJsonArray { degraded.forEach { add(it) } })
            }
        }
    }

    /**
     * What this picture is missing, said out loud. A blank rect in a screenshot is
     * indistinguishable from "the app drew nothing there", so each capture path
     * reports its own blindness from the nodes the agent already marks:
     *
     * - in-process: `pixels:unavailable` nodes (a `SurfaceView`'s own surface is
     *   composited by SurfaceFlinger, so the Canvas walk leaves a transparent hole);
     * - device-level `screencap`: `screencap:blank` windows (`FLAG_SECURE` blanks the
     *   whole frame, while the in-process capture is unaffected).
     *
     * Best-effort: a snapshot that cannot be fetched simply yields no note, since the
     * picture itself is already written.
     *
     * [client] is the client [screenshot] already built and probed healthy —
     * reused so the notes cost one snapshot fetch, not a second forward + probe.
     */
    private fun screenshotDegrades(
        client: RuntimeClient,
        viaAgent: Boolean,
    ): List<String> = runCatching {
        val snapshot = client.snapshot()
        val out = ArrayList<String>()
        for (node in snapshot.nodes.values) {
            if (viaAgent && node.pixelsUnavailable()) {
                val id = node.testId ?: node.resourceId ?: node.ref
                val where = node.frame?.let {
                    " [${it.x.toInt()},${it.y.toInt()} ${it.width.toInt()}x${it.height.toInt()}]"
                } ?: ""
                out += "$id$where is not in this picture: an in-process capture cannot read " +
                    "another process's surface (${node.typeName}). `adb exec-out screencap` can."
            }
            if (node.screencapBlank()) {
                out += if (viaAgent) {
                    "${node.ref} is a FLAG_SECURE window: this in-process picture is complete, but a " +
                        "device-level `adb exec-out screencap` of it comes back blank."
                } else {
                    "${node.ref} is a FLAG_SECURE window: THIS picture is blanked by the system. " +
                        "The in-process capture (`--package`, with the agent up) is unaffected."
                }
            }
        }
        out
    }.getOrElse { emptyList() }

    private fun typeText(
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
            before = liveSnapshot(device, pkg, params)
            landing = focusLanding(before, focus.ref)
            if (!TypeFocus.isLanded(landing)) {
                // One retarget, and only when it is not a guess: exactly one
                // focusable text input inside the node the caller named.
                val candidate = focus.ref?.let { ref ->
                    before?.let { TypeFocus.soleFocusableInput(it, ref) }
                }
                if (candidate?.frame != null) {
                    input.tap(candidate.frame!!.centerX.toInt(), candidate.frame!!.centerY.toInt())
                    Thread.sleep(FOCUS_SETTLE_MS)
                    before = liveSnapshot(device, pkg, params)
                    landing = focusLanding(before, focus.ref)
                    if (TypeFocus.isLanded(landing)) retargeted = candidate.ref
                }
                if (!TypeFocus.isLanded(landing)) {
                    throw CliError(TypeFocus.refusal(landing, focus, candidate))
                }
            }
        } else {
            before = liveSnapshot(device, pkg, params)
        }
        val field = before?.let { TypeReadback.field(it, focus?.ref) }
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
        val readback = readBackTypedText(input, device, pkg, params, before, focus?.ref, field, text, typeDelayMs)
        val submit = if (params.bool("submit")) submitAfterType(input, device, pkg, params) else null
        return buildJsonObject {
            put("gesture", "type"); put("chars", text.length)
            put("via", readback.via ?: via)
            readback.writeInto(this)
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
    private fun hideKeyboard(
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

    /** The `type` post-condition: what the field holds now, and how it got there. */
    private class Readback(
        val landed: TypeReadback.Landed,
        val landedChars: Int = 0,
        val text: String? = null,
        val unavailable: String? = null,
        val recovery: String? = null,
        /** Overrides the dispatch `via=` when a recovery re-sent the text. */
        val via: String? = null,
    ) {
        fun writeInto(builder: JsonObjectBuilder) {
            builder.put("textLanded", TypeReadback.label(landed))
            text?.let { builder.put("text", it) }
            if (landed == TypeReadback.Landed.PARTIAL) builder.put("landedChars", landedChars)
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
        Thread.sleep(READBACK_SETTLE_MS)
        val after = readFieldText(device, pkg, params, field)
            ?: return Readback(
                TypeReadback.Landed.UNREADABLE,
                unavailable = TypeReadback.Unavailable.GONE,
            )
        val landedText = TypeReadback.valueOf(after)
        if (landedText == null) {
            return Readback(
                TypeReadback.Landed.UNREADABLE,
                unavailable = TypeReadback.Unavailable.NO_TEXT_CHANNEL,
            )
        }
        val verdict = TypeReadback.classify(had, landedText, typed)
        if (!TypeReadback.isLoss(verdict.landed)) {
            return Readback(verdict.landed, verdict.landedChars, landedText)
        }
        return recoverLostText(input, device, pkg, params, after, had, typed, typeDelayMs, verdict)
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

    /** Re-find [field] in a fresh tree; null when the runtime or the node is gone. */
    private fun readFieldText(
        device: DeviceController,
        pkg: String,
        params: JsonObject,
        field: Node,
    ): Node? = liveSnapshot(device, pkg, params)?.let { TypeReadback.refind(it, field) }

    /** A fresh snapshot, or null when the runtime cannot answer for one. */
    private fun liveSnapshot(device: DeviceController, pkg: String, params: JsonObject): Snapshot? =
        runCatching {
            val client = runtimeClientFor(device, pkg, params)
            if (client.probe() is RuntimeHealth.Healthy) client.snapshot() else null
        }.getOrNull()

    /** Whether the caller supplied any field-targeting selector for `type`. */
    private fun hasInputTarget(params: JsonObject): Boolean =
        SELECTOR_KEYS.any { params.str(it) != null }

    private fun reportJson(snapshot: Snapshot, semantic: SemanticTree, compact: CompactObservation): JsonElement =
        buildJsonObject {
            put("nodeCount", snapshot.nodes.size)
            put("compactItemCount", compact.items.size)
            put("semanticNodeCount", semantic.nodes.size)
            put("snapshot", ReticleJson.compact.encodeToJsonElement(Snapshot.serializer(), snapshot))
            put("semantics", ReticleJson.compact.encodeToJsonElement(SemanticTree.serializer(), semantic))
            put("compact", ReticleJson.compact.encodeToJsonElement(CompactObservation.serializer(), compact))
        }

    private fun captureAgentScreenshot(client: RuntimeClient): ByteArray? =
        // The client already returns PNG bytes; no need to round-trip through a
        // temp file (write + read back) as this used to.
        runCatching { client.screenshotBytes() }.getOrNull()

    /** Params [resolveInputTarget]/[selectorFrom] read as a targeting selector. */
    private val SELECTOR_KEYS = listOf(
        "alias", "point", "testId", "resourceId", "css", "cssSelector", "ref", "region",
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
     * A field longer than this is not cleared for a recovery attempt. One DEL per
     * character is real input, and a long field would mean a long burst of it —
     * exactly the shape of dispatch this whole check distrusts.
     */
    private const val MAX_RECOVERY_DELETES = 64

}
