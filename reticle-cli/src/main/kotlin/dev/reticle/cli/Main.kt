package dev.reticle.cli

import dev.reticle.core.AccessibilityTree
import dev.reticle.core.CompactObservation
import dev.reticle.core.MetadataValue
import dev.reticle.core.MutationRequest
import dev.reticle.core.Point
import dev.reticle.core.PortMap
import dev.reticle.core.ReticleJson
import dev.reticle.core.RuntimeInfo
import dev.reticle.core.Selector
import dev.reticle.core.Snapshot
import java.io.File
import kotlin.system.exitProcess

/** CLI version. Kept in lockstep with the agent and plugin manifest. */
const val RETICLE_VERSION = "0.3.1"

/**
 * Reticle host CLI. Command surface:
 *
 *   reticle app launch  --package <pkg> [--serial <s>] [--port <p>]
 *   reticle ui report   --package <pkg> --output <dir>
 *   reticle ui tree     <snapshot.json> [--accessibility] [--depth N]
 *   reticle ui compact  <snapshot.json>
 *   reticle ui node     <snapshot.json> --test-id <id> | --resource-id <id> | --ref <ref>
 *   reticle act tap     --package <pkg> (--test-id|--resource-id|--ref|--point x,y)
 *   reticle act swipe   --package <pkg> --from x,y --to x,y [--duration ms]
 *   reticle act drag    --package <pkg> --from x,y --to x,y [--duration ms]
 *   reticle act type    --package <pkg> --text "..."
 *   reticle debug logs   --package <pkg> [--output file]
 *   reticle debug logcat [--serial s]
 *   reticle mutate      --package <pkg> (selector) --property p --value v
 *   reticle status      [--package <pkg>] [--serial s] [--port p]
 *   reticle doctor
 *   reticle version
 */
fun main(rawArgs: Array<String>) {
    val args = ArgList(rawArgs.toList())
    val group = args.shift() ?: run { printUsage(); exitProcess(1) }

    try {
        when (group) {
            "app" -> appGroup(args)
            "ui" -> uiGroup(args)
            "act" -> actGroup(args)
            "debug" -> debugGroup(args)
            "mutate" -> mutateCommand(args)
            "doctor" -> doctor()
            "status" -> statusCommand(args)
            "version", "--version", "-v" -> println("reticle $RETICLE_VERSION")
            "help", "--help", "-h" -> printUsage()
            else -> {
                System.err.println("unknown command group: $group")
                printUsage()
                exitProcess(1)
            }
        }
    } catch (e: CliError) {
        System.err.println("error: ${e.message}")
        exitProcess(1)
    } catch (e: AdbDeviceError) {
        System.err.println("device: ${e.message}")
        exitProcess(1)
    }
}

// --- app -----------------------------------------------------------------

private fun appGroup(args: ArgList) {
    when (val sub = args.shift()) {
        "launch" -> {
            val pkg = args.require("--package")
            val serial = args.optional("--serial") ?: defaultSerial()
            val record = RuntimeRegistry.load(serial ?: "?", pkg)
            val devicePort = resolveDevicePort(args, pkg, record)
            val hostPort = args.optional("--host-port")?.toInt() ?: record?.hostPort ?: pickHostPort(devicePort)
            val adb = Adb(serial = serial)
            adb.ensureDeviceReady()

            // Launch the app. Reticle's agent auto-starts via its ContentProvider,
            // so no special launch env is needed. Retry once: the launch monkey
            // goes over the adb shell channel, which can transiently time out.
            var launch = adb.shell("monkey -p $pkg -c android.intent.category.LAUNCHER 1")
            if (!launch.ok) {
                Thread.sleep(500)
                launch = adb.shell("monkey -p $pkg -c android.intent.category.LAUNCHER 1")
            }
            if (!launch.ok) throw CliError("failed to launch $pkg: ${launch.stderr.ifBlank { "adb shell did not complete" }}")

            val client = RuntimeClient(adb, hostPort, devicePort)
            client.setUpForward()
            val info = waitForRuntime(client, pkg, hostPort, devicePort)
            RuntimeRegistry.store(RuntimeRegistry.Record(serial ?: "?", pkg, hostPort, devicePort))

            println("launched ${info.packageName} pid=${info.pid} sdk=${info.sdkInt} agent=${info.agentVersion}")
            println("forwarded host tcp:$hostPort -> device tcp:$devicePort")
        }
        "inject" -> {
            // The UNLINKED path: load + start the runtime inside a debuggable app
            // that does NOT link the agent AAR, over JDWP (no root, no repackage).
            // The app must already be running (we inject into a live process).
            val pkg = args.require("--package")
            val serial = args.optional("--serial") ?: defaultSerial()
            val adb = Adb(serial = serial)
            adb.ensureDeviceReady()

            val injected = Injector.inject(adb, pkg)
            println("injected into $pkg pid=${injected.pid} (Bootstrap.start() -> ${injected.reportedPort})")

            // The reported port is a hint; the real proof is the loopback server
            // answering over HTTP. Forward to it and reuse the same health gate
            // every other command relies on.
            val record = RuntimeRegistry.load(serial ?: "?", pkg)
            val devicePort = resolveDevicePort(args, pkg, record)
            val hostPort = args.optional("--host-port")?.toInt() ?: record?.hostPort ?: pickHostPort(devicePort)
            val client = RuntimeClient(adb, hostPort, devicePort)
            client.setUpForward()
            val info = waitForRuntime(client, pkg, hostPort, devicePort)
            RuntimeRegistry.store(RuntimeRegistry.Record(serial ?: "?", pkg, hostPort, devicePort))

            println("runtime live: ${info.packageName} pid=${info.pid} sdk=${info.sdkInt} agent=${info.agentVersion} port=${info.port}")
            println("forwarded host tcp:$hostPort -> device tcp:$devicePort")
            println("now drive it: reticle ui report --package $pkg")
        }
        else -> throw CliError("unknown app subcommand: $sub")
    }
}

// --- ui ------------------------------------------------------------------

private fun uiGroup(args: ArgList) {
    when (val sub = args.shift()) {
        "report" -> {
            val pkg = args.require("--package")
            val outputDir = File(args.optional("--output") ?: "reticle-report")
            outputDir.mkdirs()
            withRuntime(pkg, args) { client ->
                val snapshot = client.snapshot()
                val accessibility = client.accessibility()
                val compact = CompactObservation.from(snapshot)
                File(outputDir, "snapshot.json")
                    .writeText(ReticleJson.instance.encodeToString(Snapshot.serializer(), snapshot))
                File(outputDir, "accessibility.json")
                    .writeText(ReticleJson.instance.encodeToString(AccessibilityTree.serializer(), accessibility))
                File(outputDir, "compact.json")
                    .writeText(ReticleJson.instance.encodeToString(CompactObservation.serializer(), compact))
                runCatching { client.screenshot(File(outputDir, "screenshot.png")) }
                println("wrote report to ${outputDir.path}")
                println("nodes: ${snapshot.nodes.size}, compact items: ${compact.items.size}")
            }
        }
        "screenshot" -> {
            // A screenshot path that works even WITHOUT the agent: prefer the
            // agent's /screenshot when the runtime is reachable, else fall back to
            // `adb exec-out screencap`. This is the honest degraded mode for apps
            // that don't link the agent — you can still see the screen.
            val pkg = args.optional("--package")
            val out = File(args.optional("--output") ?: "screenshot.png")
            val serial = args.optional("--serial") ?: defaultSerial()
            val adb = Adb(serial = serial)
            adb.ensureDeviceReady()

            var via: String? = null
            if (pkg != null) {
                val record = RuntimeRegistry.load(serial ?: "?", pkg)
                val devicePort = resolveDevicePort(args, pkg, record)
                val hostPort = args.optional("--host-port")?.toInt() ?: record?.hostPort ?: pickHostPort(devicePort)
                val client = RuntimeClient(adb, hostPort, devicePort)
                client.setUpForward()
                if (client.probe() is RuntimeHealth.Healthy) {
                    runCatching { client.screenshot(out) }.onSuccess { via = "agent /screenshot" }
                }
            }
            if (via == null) {
                val bytes = adb.screencap()
                if (bytes.isEmpty()) throw CliError("screencap returned no data (device ready?)")
                out.writeBytes(bytes)
                via = "adb screencap"
            }
            println("wrote ${out.path} (${out.length()} bytes) via $via")
        }
        "tree" -> {
            val snapshotFile = File(args.requirePositional("snapshot.json"))
            val depth = args.optional("--depth")?.toInt() ?: Int.MAX_VALUE
            if (args.flag("--accessibility")) {
                // Derive accessibility view from the snapshot for a single source of truth.
                val snapshot = readSnapshot(snapshotFile)
                printAccessibilityTree(AccessibilityTree.build(snapshot), depth)
            } else {
                printViewTree(readSnapshot(snapshotFile), depth)
            }
        }
        "compact" -> {
            val snapshot = readSnapshot(File(args.requirePositional("snapshot.json")))
            CompactObservation.from(snapshot).items.forEach { println(it.line()) }
        }
        "node" -> {
            val snapshot = readSnapshot(File(args.requirePositional("snapshot.json")))
            // Read each option once; optional() consumes the arg on read.
            val testId = args.optional("--test-id")
            val resourceId = args.optional("--resource-id")
            val ref = args.optional("--ref")
            val node = when {
                testId != null -> snapshot.nodes.values.firstOrNull { it.testId == testId }
                resourceId != null -> snapshot.nodes.values.firstOrNull { it.resourceId == resourceId }
                ref != null -> snapshot.nodes[ref]
                else -> throw CliError("provide --test-id, --resource-id, or --ref")
            } ?: throw CliError("no matching node")
            println(ReticleJson.instance.encodeToString(dev.reticle.core.Node.serializer(), node))
        }
        "regions" -> {
            // List sub-regions (span / virtual a11y / touch-delegate) and the
            // suspected-multi-region flag across the snapshot — the multi-click
            // surface neither the view tree nor the a11y tree exposes as nodes.
            val snapshot = readSnapshot(File(args.requirePositional("snapshot.json")))
            var any = false
            for (node in snapshot.nodes.values) {
                if (node.regions.isEmpty() && !node.suspectedMultiRegion) continue
                any = true
                val sel = node.testId?.let { "#$it" } ?: node.resourceId?.let { "@$it" } ?: node.ref
                println("$sel ${node.role ?: node.typeName}${node.text?.let { " \"${it.take(40)}\"" } ?: ""}")
                if (node.suspectedMultiRegion) {
                    println("    ⚠ suspectedMultiRegion: self-drawn control, sub-regions not exposed via any standard channel")
                    node.charGrid?.let { g ->
                        println("    charGrid: ${g.lines.size} line(s)${if (g.approximate) " (approximate)" else ""} — target a substring with `act tap --region \"…\"`")
                    }
                }
                for (r in node.regions) {
                    val rect = r.rects.firstOrNull()
                    val where = rect?.let { "[${it.x.toInt()},${it.y.toInt()} ${it.width.toInt()}x${it.height.toInt()}]" } ?: "(no rect)"
                    val tgt = r.target?.let { " -> $it" } ?: ""
                    val color = r.color?.let { " color=$it" } ?: ""
                    println("    • ${r.source} \"${r.label?.take(40) ?: ""}\"$tgt$color $where")
                }
            }
            if (!any) println("(no multi-region nodes found)")
        }
        else -> throw CliError("unknown ui subcommand: $sub")
    }
}

// --- act -----------------------------------------------------------------

private fun actGroup(args: ArgList) {
    val sub = args.shift() ?: throw CliError("act needs a subcommand")
    val pkg = args.require("--package")
    val serial = args.optional("--serial") ?: defaultSerial()
    val adb = Adb(serial = serial)
    adb.ensureDeviceReady()
    val input = InputBackend(adb)

    when (sub) {
        "tap" -> {
            withRuntime(pkg, args, adb, serial) { client ->
                val point = resolvePoint(client, args)
                input.tap(point.x.toInt(), point.y.toInt())
                println("tap ${point.x.toInt()},${point.y.toInt()}")
            }
        }
        "swipe" -> {
            val (fx, fy) = parsePoint(args.require("--from"))
            val (tx, ty) = parsePoint(args.require("--to"))
            val duration = args.optional("--duration")?.toInt() ?: 300
            input.swipe(fx, fy, tx, ty, duration)
            println("swipe $fx,$fy -> $tx,$ty (${duration}ms)")
        }
        "drag" -> {
            val (fx, fy) = parsePoint(args.require("--from"))
            val (tx, ty) = parsePoint(args.require("--to"))
            val duration = args.optional("--duration")?.toInt() ?: 1000
            input.drag(fx, fy, tx, ty, duration)
            println("drag $fx,$fy -> $tx,$ty (${duration}ms)")
        }
        "type" -> {
            val text = args.require("--text")
            input.text(text)
            println("typed ${text.length} chars")
        }
        else -> throw CliError("unknown act subcommand: $sub")
    }
}

// --- debug ---------------------------------------------------------------

private fun debugGroup(args: ArgList) {
    when (val sub = args.shift()) {
        "logs" -> {
            val pkg = args.require("--package")
            withRuntime(pkg, args) { client ->
                val batch = client.logs()
                val json = ReticleJson.instance.encodeToString(dev.reticle.core.LogBatch.serializer(), batch)
                val output = args.optional("--output")
                if (output != null) {
                    File(output).writeText(json)
                    println("wrote ${batch.entries.size} log entries to $output")
                } else if (batch.entries.isEmpty()) {
                    // Reaching here means the runtime ANSWERED (withRuntime's health
                    // gate passed) but returned no entries. Say so explicitly — an
                    // empty stdout is otherwise indistinguishable from a failure, and
                    // most apps simply never call the agent's logging API.
                    println("(runtime reachable, but it has 0 app-authored log entries)")
                    println("  these are logs the APP emits via Reticle's logging API, not logcat.")
                    println("  for the agent's own startup/lifecycle lines, use: reticle debug logcat")
                } else {
                    batch.entries.forEach { println("[${it.level}] ${it.message} ${it.metadata}") }
                }
            }
        }
        "logcat" -> {
            // The agent's OWN logcat lines — works even when the runtime is
            // unreachable over HTTP (which `debug logs` requires). This is how you
            // tell "agent not linked" (no Reticle lines at all) from "linked but
            // failed to bind its port" (a FAILED-to-bind line).
            args.optional("--package") // accepted for symmetry; logcat is process-wide
            val serial = args.optional("--serial") ?: defaultSerial()
            val adb = Adb(serial = serial)
            val lines = adb.reticleLogcat()
            if (lines.isEmpty()) {
                println("(no '${Adb.LOG_TAG}' logcat lines)")
                println("  the agent has not logged — it is likely not linked into the app,")
                println("  or logcat was cleared. Confirm the reticle-agent AAR is a dependency.")
            } else {
                lines.forEach { println(it) }
            }
        }
        else -> throw CliError("unknown debug subcommand: $sub")
    }
}

// --- mutate --------------------------------------------------------------

private fun mutateCommand(args: ArgList) {
    val pkg = args.require("--package")
    val property = args.require("--property")
    val rawValue = args.require("--value")
    withRuntime(pkg, args) { client ->
        val selector = selectorFrom(args)
        val request = MutationRequest(selector, property, parseValue(rawValue))
        val result = client.mutate(request)
        if (result.applied) {
            println("mutated ${result.ref} $property (was ${result.previousValue?.displayString()})")
        } else {
            throw CliError(result.message ?: "mutation failed")
        }
    }
}

// --- doctor --------------------------------------------------------------

private fun doctor() {
    val adb = Adb()
    println("reticle: $RETICLE_VERSION")
    println("adb: ${Adb.resolveAdbPath()}")
    val version = adb.run("version")
    println(version.stdout.lineSequence().firstOrNull() ?: "adb not found")
    val states = adb.listDeviceStates()
    when {
        states.isEmpty() -> println("devices: none (start an emulator or connect a device)")
        states.all { it.state == "device" } -> println("devices: ${states.joinToString(", ") { it.serial }}")
        else -> {
            // Surface non-ready devices explicitly — `offline`/`unauthorized` is the
            // single most common reason commands later "hang" or fail mysteriously.
            println("devices:")
            states.forEach { s ->
                val hint = when (s.state) {
                    "device" -> "ready"
                    "offline" -> "OFFLINE — re-plug USB / `adb reconnect`"
                    "unauthorized" -> "UNAUTHORIZED — accept the debugging prompt on the device"
                    else -> s.state
                }
                println("  ${s.serial}  [$hint]")
            }
        }
    }
    println("registry: ${RuntimeRegistry.all().size} stored runtime(s)")
}

// --- status --------------------------------------------------------------

/**
 * Report the live health of a package's Reticle runtime: device state, whether
 * the app process is up, the forwarded port, and a classified probe of
 * `/runtime` (healthy / unreachable / unresponsive / foreign + conflict). This
 * is the diagnostic to run *before* a snapshot when something looks wrong.
 */
private fun statusCommand(args: ArgList) {
    val pkg = args.optional("--package")
    val serial = args.optional("--serial") ?: defaultSerial()
    val adb = Adb(serial = serial)

    println("reticle: $RETICLE_VERSION")
    val states = adb.listDeviceStates()
    val target = serial ?: states.singleOrNull { it.state == "device" }?.serial
    val targetState = states.firstOrNull { it.serial == target }?.state
    println("device: ${target ?: "none"}${targetState?.let { " [$it]" } ?: ""}")
    if (target == null) {
        println("  no ready device — connect one or pass --serial")
        return
    }
    if (targetState != null && targetState != "device") {
        println("  device not ready ($targetState); fix that before probing the runtime")
        return
    }
    if (pkg == null) {
        // No package: just list what the registry knows so the user can pick one.
        val records = RuntimeRegistry.all()
        if (records.isEmpty()) {
            println("registry: empty — run `reticle app launch --package <pkg>` first")
        } else {
            println("registry:")
            records.forEach { println("  ${it.packageName}  host tcp:${it.hostPort} -> device tcp:${it.devicePort} (serial ${it.serial})") }
            println("re-run with --package <pkg> for a live health probe")
        }
        return
    }

    val running = adb.pidOf(pkg)
    println("app: $pkg ${running?.let { "running (pid=$it)" } ?: "NOT running"}")

    val record = RuntimeRegistry.load(serial ?: "?", pkg)
    val devicePort = resolveDevicePort(args, pkg, record)
    val hostPort = args.optional("--host-port")?.toInt() ?: record?.hostPort ?: pickHostPort(devicePort)
    val client = RuntimeClient(adb, hostPort, devicePort)
    client.setUpForward()
    println("forward: host tcp:$hostPort -> device tcp:$devicePort")

    when (val health = client.probe()) {
        is RuntimeHealth.Healthy -> {
            val info = health.info
            val match = info.packageName == pkg
            println("runtime: HEALTHY — ${info.packageName} pid=${info.pid} sdk=${info.sdkInt} agent=${info.agentVersion} port=${info.port}")
            if (match) {
                println("identity: OK (serving the requested package)")
            } else {
                println("identity: CONFLICT — port is served by '${info.packageName}', not '$pkg'")
                println("  device loopback ports are process-global; another linked app holds tcp:$devicePort.")
                println("  → target it with --package ${info.packageName}, or give '$pkg' a different RETICLE_PORT and pass --port.")
            }
        }
        is RuntimeHealth.Unreachable -> {
            println("runtime: UNREACHABLE — connection refused on tcp:$devicePort")
            if (running == null) {
                println("  the app isn't running. Launch it: reticle app launch --package $pkg")
            } else {
                // Use the agent's own logcat to turn a guess into a determination:
                // a "FAILED to bind" line means the agent IS linked but lost the
                // port race; no Reticle lines at all means it isn't linked.
                val agentLog = adb.reticleLogcat()
                val bindFailed = agentLog.any { it.contains("FAILED to bind", ignoreCase = true) }
                val started = agentLog.any { it.contains("Reticle started", ignoreCase = true) }
                when {
                    bindFailed -> {
                        println("  the reticle-agent IS linked but FAILED to bind its port (see logcat):")
                        agentLog.filter { it.contains("bind", ignoreCase = true) }.takeLast(2).forEach { println("    $it") }
                        println("  → another process holds tcp:$devicePort; give '$pkg' a distinct RETICLE_PORT.")
                    }
                    started -> println("  the agent logged a start but isn't answering now — try relaunching the app.")
                    agentLog.isEmpty() -> {
                        println("  no '${Adb.LOG_TAG}' logcat lines: the agent is likely NOT linked into this")
                        println("  build (see SKILL.md prerequisites). Confirm via: reticle debug logcat")
                    }
                    else -> println("  the app is running but no server is listening — see: reticle debug logcat")
                }
            }
        }
        is RuntimeHealth.Unresponsive -> {
            println("runtime: UNRESPONSIVE — connected but no response (${health.detail})")
            println("  stale/zombie listen socket or a hung server thread.")
            println("  → adb shell am force-stop $pkg && reticle app launch --package $pkg")
        }
        is RuntimeHealth.Foreign -> {
            println("runtime: FOREIGN — port answered but not as a Reticle runtime (${health.sample})")
            println("  another server squats on tcp:$devicePort; choose a different --port.")
        }
    }
}

// --- shared helpers ------------------------------------------------------

private fun withRuntime(
    pkg: String,
    args: ArgList,
    existingAdb: Adb? = null,
    existingSerial: String? = null,
    block: (RuntimeClient) -> Unit,
) {
    // When the caller already built the Adb (e.g. actGroup), it also already
    // consumed `--serial`; re-reading it here would return null and wrongly fall
    // back to defaultSerial() (which throws with >1 device). Reuse the caller's.
    val serial = if (existingAdb != null) existingSerial else (args.optional("--serial") ?: defaultSerial())
    val adb = existingAdb ?: Adb(serial = serial)
    adb.ensureDeviceReady()
    val record = RuntimeRegistry.load(serial ?: "?", pkg)
    val devicePort = resolveDevicePort(args, pkg, record)
    val hostPort = args.optional("--host-port")?.toInt() ?: record?.hostPort ?: pickHostPort(devicePort)
    val client = RuntimeClient(adb, hostPort, devicePort)
    client.setUpForward()
    // Gate the heavy endpoints behind a fast, classifying health + identity probe
    // so a dead/foreign/hung server fails in ~2s with a precise message instead of
    // hanging for 15s and dumping a SocketTimeoutException stack trace.
    assertHealthyRuntime(client, pkg, hostPort, devicePort)
    RuntimeRegistry.store(RuntimeRegistry.Record(serial ?: "?", pkg, hostPort, devicePort))
    block(client)
}

/**
 * Probe `/runtime` once and turn anything but a matching, healthy agent into an
 * actionable [CliError]. The identity check is the conflict guard: device
 * loopback ports are process-global, so a forward can silently land on a
 * *different* app's Reticle server (or a stale one) — we refuse to act on it.
 */
private fun assertHealthyRuntime(
    client: RuntimeClient,
    pkg: String,
    hostPort: Int,
    devicePort: Int,
) {
    when (val health = client.probe()) {
        is RuntimeHealth.Healthy -> {
            val running = health.info.packageName
            if (running != pkg) {
                throw CliError(
                    "port conflict: device tcp:$devicePort is served by '$running', not '$pkg'.\n" +
                        "  Another Reticle-linked app holds the runtime port. Either:\n" +
                        "    - target that app:           --package $running\n" +
                        "    - or give this app its own:  relaunch with --port <other> (set RETICLE_PORT in that app)\n" +
                        "  Inspect with: reticle status --package $pkg"
                )
            }
        }
        is RuntimeHealth.Unreachable -> throw CliError(
            "no Reticle runtime on device tcp:$devicePort (connection refused).\n" +
                "  The app '$pkg' is not exposing the agent. Either it isn't running, or the\n" +
                "  reticle-agent AAR is not linked into this build (see SKILL.md prerequisites).\n" +
                "  Launch first with: reticle app launch --package $pkg"
        )
        is RuntimeHealth.Unresponsive -> throw CliError(
            "Reticle runtime on device tcp:$devicePort connected but did not respond (${health.detail}).\n" +
                "  Usually a stale/zombie listen socket from a previous process, or a hung server.\n" +
                "  Fix: force-stop and relaunch the app, then retry:\n" +
                "    adb shell am force-stop $pkg && reticle app launch --package $pkg\n" +
                "  Diagnose with: reticle status --package $pkg"
        )
        is RuntimeHealth.Foreign -> throw CliError(
            "device tcp:$devicePort answered but not with a Reticle runtime (got: ${health.sample}).\n" +
                "  Some other server is squatting on this port. Pick a different port with --port <n>."
        )
    }
}

private fun resolvePoint(client: RuntimeClient, args: ArgList): Point {
    args.optional("--point")?.let {
        val (x, y) = parsePoint(it)
        return Point(x.toDouble(), y.toDouble())
    }
    val snapshot = client.snapshot()
    val accessibility = client.accessibility()
    val resolver = SelectorResolver(snapshot, accessibility)
    val resolved = resolver.resolve(selectorFrom(args))
        ?: throw CliError("could not resolve selector to a point")
    System.err.println("resolved via ${resolved.source} -> ref=${resolved.ref}")
    return resolved.point
}

private fun selectorFrom(args: ArgList): Selector = Selector(
    testId = args.optional("--test-id"),
    resourceId = args.optional("--resource-id"),
    ref = args.optional("--ref"),
    point = args.optional("--point")?.let { val (x, y) = parsePoint(it); Point(x.toDouble(), y.toDouble()) },
    region = args.optional("--region"),
)

private fun parsePoint(value: String): Pair<Int, Int> {
    val parts = value.split(",")
    if (parts.size != 2) throw CliError("expected x,y but got '$value'")
    return parts[0].trim().toInt() to parts[1].trim().toInt()
}

private fun parseValue(raw: String): MetadataValue = when {
    raw == "true" || raw == "false" -> MetadataValue.Bool(raw.toBoolean())
    raw.toLongOrNull() != null -> MetadataValue.Integer(raw.toLong())
    raw.toDoubleOrNull() != null -> MetadataValue.Real(raw.toDouble())
    else -> MetadataValue.Text(raw)
}

private fun readSnapshot(file: File): Snapshot {
    if (!file.exists()) throw CliError("snapshot file not found: ${file.path}")
    return ReticleJson.instance.decodeFromString(Snapshot.serializer(), file.readText())
}

/**
 * Poll `/runtime` until the agent for [pkg] answers, then return its info.
 *
 * Distinguishes the two launch failure modes the old loop hid:
 *  - a *foreign* healthy server already on the port (a different app) is a hard
 *    conflict — fail immediately, don't waste the timeout budget;
 *  - merely unreachable/unresponsive during cold start is expected — keep waiting.
 */
private fun waitForRuntime(
    client: RuntimeClient,
    pkg: String,
    hostPort: Int,
    devicePort: Int,
    attempts: Int = 30,
): RuntimeInfo {
    var last: RuntimeHealth? = null
    repeat(attempts) {
        val health = client.probe()
        last = health
        when (health) {
            is RuntimeHealth.Healthy -> {
                if (health.info.packageName == pkg) return health.info
                // A different app already serves this port — waiting won't help.
                assertHealthyRuntime(client, pkg, hostPort, devicePort)
            }
            else -> Thread.sleep(250) // still coming up; keep polling.
        }
    }
    // Exhausted attempts: surface the most informative classification we saw.
    when (val h = last) {
        is RuntimeHealth.Unresponsive -> throw CliError(
            "timed out waiting for '$pkg': the runtime port connected but never responded (${h.detail}).\n" +
                "  Likely a stale socket from a prior run. Try: adb shell am force-stop $pkg, then relaunch."
        )
        else -> throw CliError(
            "timed out waiting for the Reticle runtime for '$pkg'.\n" +
                "  Is the reticle-agent AAR linked into this build? (see SKILL.md prerequisites)\n" +
                "  Diagnose with: reticle status --package $pkg"
        )
    }
}

private fun defaultSerial(): String? {
    // Honor the adb-standard $ANDROID_SERIAL the same way adb itself does, so a
    // shell that already exported it (the common multi-device setup) doesn't have
    // to repeat --serial on every command. Precedence matches adb: an explicit
    // --serial (handled by callers) wins; then $ANDROID_SERIAL; then a lone
    // device; otherwise we refuse to guess.
    System.getenv("ANDROID_SERIAL")?.trim()?.takeIf { it.isNotEmpty() }?.let { envSerial ->
        val states = Adb().listDeviceStates()
        // Validate it — a stale/typo'd env var pointing at an absent device should
        // fail loudly here, not later as a confusing "device offline" deep in adb.
        if (states.none { it.serial == envSerial }) {
            throw CliError(
                "\$ANDROID_SERIAL is '$envSerial' but no such device is attached " +
                    "(${states.joinToString(", ") { it.serial }.ifEmpty { "none" }}). " +
                    "Unset it or pass --serial <one>."
            )
        }
        return envSerial
    }
    val devices = Adb().listDevices()
    return when (devices.size) {
        0 -> null // let downstream device-readiness checks produce the message
        1 -> devices.single()
        // Multiple ready devices: refuse to guess — an action on the wrong device
        // is worse than a clear error asking which one.
        else -> throw CliError(
            "multiple devices connected (${devices.joinToString(", ")}); " +
                "pass --serial <one>, or export ANDROID_SERIAL=<one>."
        )
    }
}

private fun pickHostPort(devicePort: Int): Int = devicePort

/**
 * The device loopback port to forward to, in precedence order:
 *   1. an explicit `--port`,
 *   2. a previously recorded port for this serial+package,
 *   3. the per-app port derived from the package name (matches what the agent
 *      binds), so different apps don't collide on a single fixed port.
 */
private fun resolveDevicePort(args: ArgList, pkg: String, record: RuntimeRegistry.Record?): Int =
    args.optional("--port")?.toInt() ?: record?.devicePort ?: PortMap.derivePort(pkg)

private fun printViewTree(snapshot: Snapshot, maxDepth: Int) {
    fun walk(ref: String, depth: Int) {
        if (depth > maxDepth) return
        val node = snapshot.nodes[ref] ?: return
        val indent = "  ".repeat(depth)
        val sel = node.testId?.let { "#$it" } ?: node.resourceId?.let { "@$it" } ?: node.ref
        val label = node.text ?: node.contentDescription
        println("$indent$sel ${node.role ?: node.typeName}${label?.let { " \"${it.take(30)}\"" } ?: ""}")
        node.children.forEach { walk(it, depth + 1) }
    }
    walk(snapshot.rootRef, 0)
}

private fun printAccessibilityTree(tree: AccessibilityTree, maxDepth: Int) {
    fun walk(ref: String, depth: Int) {
        if (depth > maxDepth) return
        val node = tree.nodes[ref] ?: return
        val indent = "  ".repeat(depth)
        val sel = node.testId?.let { "#$it" } ?: node.resourceId?.let { "@$it" } ?: node.ref
        println("$indent$sel ${node.role}${node.label?.let { " \"${it.take(30)}\"" } ?: ""}")
        node.children.forEach { walk(it, depth + 1) }
    }
    // The structural root (application) is usually dropped from the
    // accessibility view because it carries no a11y signal, so start from the
    // surviving top-level nodes: those whose parent is not itself accessible.
    val roots = tree.nodes.values
        .filter { it.parentRef == null || !tree.nodes.containsKey(it.parentRef) }
        .map { it.ref }
    if (roots.isEmpty()) {
        println("(no accessibility nodes)")
    } else {
        roots.forEach { walk(it, 0) }
    }
}

private fun printUsage() {
    println(
        """
        reticle — runtime UI evidence + action harness for Android apps

        app launch   --package <pkg> [--serial <s>] [--port <devicePort>]
        app inject   --package <pkg> [--serial <s>]   # start the runtime in a running debuggable app w/o the AAR (JDWP)
        ui report    --package <pkg> [--output <dir>]
        ui screenshot [--package <pkg>] [--output <file>]   # agent if linked, else adb screencap
        ui tree      <snapshot.json> [--accessibility] [--depth N]
        ui compact   <snapshot.json>
        ui node      <snapshot.json> (--test-id|--resource-id|--ref)
        ui regions   <snapshot.json>                 # sub-regions in single nodes
        act tap      --package <pkg> (--test-id|--resource-id|--ref|--point x,y) [--region "substr"]
        act swipe    --package <pkg> --from x,y --to x,y [--duration ms]
        act drag     --package <pkg> --from x,y --to x,y [--duration ms]
        act type     --package <pkg> --text "..."
        debug logs   --package <pkg> [--output <file>]
        debug logcat [--serial <s>]                  # the agent's own startup logs
        mutate       --package <pkg> (selector) --property <p> --value <v>
        status       [--package <pkg>] [--serial <s>] [--port <devicePort>]
        doctor
        version
        """.trimIndent()
    )
}

// --- tiny arg parser -----------------------------------------------------

private class ArgList(initial: List<String>) {
    private val remaining = ArrayDeque(initial)
    private val positionals = ArrayDeque<String>()

    init {
        // Pre-scan is not needed; we parse lazily but keep order for positionals.
    }

    fun shift(): String? = remaining.removeFirstOrNull()

    fun optional(name: String): String? {
        val idx = remaining.indexOf(name)
        if (idx < 0) return null
        remaining.removeAt(idx)
        return if (idx < remaining.size) remaining.removeAt(idx) else null
    }

    fun flag(name: String): Boolean {
        val idx = remaining.indexOf(name)
        if (idx < 0) return false
        remaining.removeAt(idx)
        return true
    }

    fun require(name: String): String =
        optional(name) ?: throw CliError("missing required option $name")

    fun requirePositional(label: String): String {
        // The first non-option token is the positional.
        val idx = remaining.indexOfFirst { !it.startsWith("--") }
        if (idx < 0) throw CliError("missing required argument <$label>")
        return remaining.removeAt(idx)
    }
}

class CliError(message: String) : RuntimeException(message)
