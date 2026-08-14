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
            "type" -> HelperTypeText.typeText(input, device, pkg, params)
            "hideKeyboard", "hide-keyboard" -> HelperTypeText.hideKeyboard(input, device, pkg, params)
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

    /** A fresh snapshot, or null when the runtime cannot answer for one. */
    fun liveSnapshot(device: DeviceController, pkg: String, params: JsonObject): Snapshot? =
        runCatching {
            val client = runtimeClientFor(device, pkg, params)
            if (client.probe() is RuntimeHealth.Healthy) client.snapshot() else null
        }.getOrNull()

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

    /**
     * Time for the page to receive the touch before asking it what it received. The
     * dispatch returns as soon as the event is injected; the page's own listener runs
     * after that, and reading too early would report an absence as a miss.
     */
    private const val DOM_LANDING_SETTLE_MS = 200L
}
