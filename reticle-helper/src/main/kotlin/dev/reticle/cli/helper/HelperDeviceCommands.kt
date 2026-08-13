package dev.reticle.cli

import dev.reticle.cli.platform.DeviceController
import dev.reticle.cli.platform.InputDispatcher
import dev.reticle.cli.platform.android.Adb
import dev.reticle.cli.platform.android.Injector
import dev.reticle.cli.platform.android.InputBackend
import dev.reticle.core.CompactObservation
import dev.reticle.core.DomRectCheck
import dev.reticle.core.DomTapWitness
import dev.reticle.core.MutationRequest
import dev.reticle.core.Node
import dev.reticle.core.NodeKind
import dev.reticle.core.ReticleJson
import dev.reticle.core.SelectorResolver
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
                // Judged BEFORE the touch: after it the screen this coordinate was
                // aimed at may not exist any more.
                val coverage = if (rawPoint) {
                    pointCoverage(device, pkg, params, traceBefore?.snapshot, target!!.point.x, target!!.point.y)
                } else {
                    null
                }
                // Judged BEFORE the touch as well, and for EVERY tap rather than
                // only a coordinate one: a selector tap is the case that was silent
                // here. It resolves, confirms the rect has stopped moving, reports
                // `settled=1` — and then hands the touch to whatever is drawn over
                // that point. See [ScreenCoverage.obstruction].
                val obstruction = tapObstruction(
                    device, pkg, params, traceBefore?.snapshot,
                    target!!.point.x, target!!.point.y, target!!.ref,
                )
                input.tap(x, y)
                // Asked AFTER the touch, because the answer only exists once the page has
                // received one. The one fact about a tap that comes from the page rather
                // than from Reticle's own arithmetic.
                val landing = domTapLanding(device, pkg, params, traceBefore?.snapshot, target!!)
                buildJsonObject {
                    put("gesture", "tap")
                    put("x", x)
                    put("y", y)
                    coverage?.let { put("coverage", it) }
                    obstruction?.let { put("obstruction", it) }
                    put("source", target!!.source)
                    target!!.ref?.let { put("ref", it) }
                    // The frame was only partly reachable and the tap was aimed at
                    // the visible part instead of at its centre. Said out loud: the
                    // coordinate no longer matches the rect the caller can read in
                    // the tree, and the difference is the evidence.
                    target!!.reachNote?.let { put("reach", it) }
                    // Honest flag, as in scroll-to: false means the target was still
                    // moving when the budget lapsed, so this tap may have been aimed
                    // at a point that had already changed.
                    stable?.let { put("settled", it) }
                    // The evidence that the first read WAS stale: the same selector,
                    // same ref, different coordinates. Without this the confirm would
                    // silently fix the tap and the caller would never learn that the
                    // screen it reasoned about had moved under it.
                    TapSettlePolicy.movedBy(first.point, target!!.point)?.let { put("rectMoved", it) }
                    // A DOM rect folded to a point outside the web view that draws
                    // it: impossible for a correct fold, and silent until now — the
                    // tap dispatches at the reported centre and reports settled=1.
                    domRectComplaint(traceBefore?.snapshot, target!!.ref)?.let {
                        put("rectSuspect", it)
                    }
                    // Where the touch ACTUALLY landed, according to the page. Quiet when
                    // it landed on the element aimed at (or inside it), which is every
                    // ordinary tap — a warning that fires everywhere is one nobody reads.
                    landing?.let { put("landed", it) }
                    // The node this selector resolved publishes NO control of its
                    // own: it is a caption, a wrapper, a plain row. The touch was
                    // still dispatched — a framework-built field binds its handler in
                    // JS and publishes no role, no tabindex and no `aria-*`, so the
                    // row really is driven this way — but "I tapped a control" and "I
                    // tapped a caption and relied on the app's own handler" are
                    // different claims, and only the first one is evidence.
                    //
                    // Measured on a real Vue form: five field rows (`Education level`,
                    // `Employment type`, …) captured as plain `div`/`label` with no
                    // tappable marker, so an agent went to coordinates for all five
                    // — four commands per field — while a `--label` tap on the caption
                    // drives them in one.
                    inertTargetNote(traceBefore?.snapshot, target!!.ref)?.let {
                        put("targetInert", it)
                    }
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
            "wheel" -> HelperWheel.run(input, device, pkg, params)
            "type" -> typeText(input, device, pkg, params)
            "hideKeyboard", "hide-keyboard" -> hideKeyboard(input, device, pkg, params)
            // The one gesture that dispatches no input: it only observes. Kept
            // under `act` because it is part of an action sequence (act, then wait
            // for the consequence) and shares the selector/trace surface.
            "wait" -> HelperWait.run(device, pkg, params)
            // `activate` is iOS-only and exists BECAUSE iOS lacks what Android has.
            // It drives a control in-process (`sendActions`, the agent's /activate
            // endpoint) — the only input path on a real iOS device, and the fallback
            // when a simulator's private HID surface will not initialize. Android
            // synthesizes real input through `adb shell input`, so there is nothing
            // for it to fall back FROM. Saying "unknown gesture" for it sent the
            // caller looking for a typo, and `docs/boundaries.md` plus a line in the
            // skill recommend it without naming the platform, so a reader arrives
            // here honestly.
            "activate" -> throw CliError(
                "act activate is iOS-only: it activates a control in-process because a real iOS device " +
                    "exposes no host-reachable HID surface. Android synthesizes real input instead — use " +
                    "`act tap` with the same selector (`--css` included), which dispatches an actual touch."
            )
            else -> throw CliError(
                "unknown act gesture '$sub' " +
                    "(tap/swipe/drag/scroll-to/wheel/type/hide-keyboard/wait; " +
                    "activate is iOS-only)"
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
            before = liveSnapshot(device, pkg, params)
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
                    before = liveSnapshot(device, pkg, params)
                    targetRef = targetRefIn(before, params, focus.ref)
                    landing = focusLanding(before, targetRef)
                    if (TypeFocus.isLanded(landing)) retargeted = candidate.ref
                }
                if (!TypeFocus.isLanded(landing)) {
                    throw CliError(TypeFocus.refusal(landing, focus, candidate))
                }
            }
        } else {
            before = liveSnapshot(device, pkg, params)
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
     * The rect-fold complaint for a DOM target, when the pre-action snapshot is at
     * hand. Silent otherwise: a check that could not run is not evidence, and the
     * trace's own capture is the one already paid for.
     */
    private fun domRectComplaint(before: Snapshot?, ref: String?): String? {
        val snapshot = before ?: return null
        val target = ref ?: return null
        return DomRectCheck.outsideHost(snapshot, target)
    }

    /**
     * Ask the PAGE where the touch went, for a tap that resolved to a DOM node.
     *
     * The one check on a tap that is not Reticle's own arithmetic. Every other answer a
     * tap gives is about its intent: the selector resolved, the rect was re-read and had
     * stopped moving, the coordinate was dispatched. If the page-to-device fold is wrong,
     * all of that stays true while the touch lands somewhere else and the result still
     * reads `settled=1` — measured at roughly 130px on a real hybrid page (#234).
     *
     * Costs one snapshot, and only on a DOM tap: the witness's record lives in the page,
     * so it has to be read after the gesture. Silent whenever it cannot judge — a
     * selector that no longer resolves (the tap navigated), an unreadable page, a sealed
     * frame — because a check that could not run is not evidence. See [DomTapWitness].
     */
    private fun domTapLanding(
        device: DeviceController,
        pkg: String,
        params: JsonObject,
        before: Snapshot?,
        target: ResolvedInputTarget,
    ): String? {
        if (!target.source.startsWith("dom")) {
            // A `--css` selector always resolves through the DOM; anything else is only
            // a DOM tap if the node it hit is one, which the pre-action capture knows.
            val ref = target.ref ?: return null
            val node = before?.nodes?.get(ref) ?: return null
            if (node.kind != NodeKind.domNode) return null
        }
        val selector = selectorOrNull(params) ?: return null
        // Let the page's own handler run before asking it what it received.
        Thread.sleep(DOM_LANDING_SETTLE_MS)
        val after = runCatching { liveSnapshot(device, pkg, params) }.getOrNull() ?: return null
        val resolved = runCatching {
            SelectorResolver(after, SemanticTree.build(after)).resolve(selector)?.ref
        }.getOrNull() ?: return null
        return runCatching { DomTapWitness.describe(after, resolved) }.getOrNull()
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

    /** Re-find [field] in a fresh tree; null when the runtime or the node is gone. */
    /**
     * A note when the tap's resolved node published no interactivity of its own.
     *
     * Null for an ordinary control, so the marker means exactly one thing when it
     * appears. Not a refusal and not a warning about the touch: nothing says the tap
     * is wrong, only that the tree did not vouch for the target. See the call site
     * for the measurement.
     */
    private fun inertTargetNote(snapshot: Snapshot?, ref: String?): String? {
        val node = ref?.let { snapshot?.nodes?.get(it) } ?: return null
        if (node.isInteractive) return null
        val what = node.role ?: node.typeName
        return "the resolved node ($ref, $what) publishes no control of its own — the touch was " +
            "dispatched at its centre and only the app's own handler can act on it, so treat this " +
            "as a coordinate-grade tap and verify the effect"
    }

    private fun readFieldText(
        device: DeviceController,
        pkg: String,
        params: JsonObject,
        field: Node,
    ): Node? = liveSnapshot(device, pkg, params)?.let { TypeReadback.refind(it, field) }

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
     * Time for the page to receive the touch before asking it what it received. The
     * dispatch returns as soon as the event is injected; the page's own listener runs
     * after that, and reading too early would report an absence as a miss.
     */
    private const val DOM_LANDING_SETTLE_MS = 200L

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
