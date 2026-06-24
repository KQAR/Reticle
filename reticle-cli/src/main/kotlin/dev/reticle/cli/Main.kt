package dev.reticle.cli

import dev.reticle.core.AccessibilityTree
import dev.reticle.core.CompactObservation
import dev.reticle.core.MetadataValue
import dev.reticle.core.MutationRequest
import dev.reticle.core.Point
import dev.reticle.core.ReticleJson
import dev.reticle.core.Selector
import dev.reticle.core.Snapshot
import java.io.File
import kotlin.system.exitProcess

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
 *   reticle debug logs  --package <pkg> [--output file]
 *   reticle mutate      --package <pkg> (selector) --property p --value v
 *   reticle doctor
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
    }
}

// --- app -----------------------------------------------------------------

private fun appGroup(args: ArgList) {
    when (val sub = args.shift()) {
        "launch" -> {
            val pkg = args.require("--package")
            val serial = args.optional("--serial") ?: defaultSerial()
            val devicePort = args.optional("--port")?.toInt() ?: 8765
            val hostPort = args.optional("--host-port")?.toInt() ?: pickHostPort(devicePort)
            val adb = Adb(serial = serial)

            // Launch the app. Reticle's agent auto-starts via its ContentProvider,
            // so no special launch env is needed.
            val launch = adb.shell("monkey -p $pkg -c android.intent.category.LAUNCHER 1")
            if (!launch.ok) throw CliError("failed to launch $pkg: ${launch.stderr}")

            val client = RuntimeClient(adb, hostPort, devicePort)
            client.setUpForward()
            waitForRuntime(client)
            RuntimeRegistry.store(RuntimeRegistry.Record(serial ?: "?", pkg, hostPort, devicePort))

            val info = client.runtime()
            println("launched ${info.packageName} pid=${info.pid} sdk=${info.sdkInt} agent=${info.agentVersion}")
            println("forwarded host tcp:$hostPort -> device tcp:$devicePort")
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
    val input = InputBackend(adb)

    when (sub) {
        "tap" -> {
            withRuntime(pkg, args, adb) { client ->
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
                } else {
                    batch.entries.forEach { println("[${it.level}] ${it.message} ${it.metadata}") }
                }
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
    println("adb: ${Adb.resolveAdbPath()}")
    val version = adb.run("version")
    println(version.stdout.lineSequence().firstOrNull() ?: "adb not found")
    val devices = adb.listDevices()
    if (devices.isEmpty()) {
        println("devices: none (start an emulator or connect a device)")
    } else {
        println("devices: ${devices.joinToString(", ")}")
    }
    println("registry: ${RuntimeRegistry.all().size} stored runtime(s)")
}

// --- shared helpers ------------------------------------------------------

private fun withRuntime(
    pkg: String,
    args: ArgList,
    existingAdb: Adb? = null,
    block: (RuntimeClient) -> Unit,
) {
    val serial = args.optional("--serial") ?: defaultSerial()
    val adb = existingAdb ?: Adb(serial = serial)
    val record = RuntimeRegistry.load(serial ?: "?", pkg)
    val devicePort = args.optional("--port")?.toInt() ?: record?.devicePort ?: 8765
    val hostPort = args.optional("--host-port")?.toInt() ?: record?.hostPort ?: pickHostPort(devicePort)
    val client = RuntimeClient(adb, hostPort, devicePort)
    client.setUpForward()
    RuntimeRegistry.store(RuntimeRegistry.Record(serial ?: "?", pkg, hostPort, devicePort))
    block(client)
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

private fun waitForRuntime(client: RuntimeClient, attempts: Int = 30) {
    repeat(attempts) { i ->
        try {
            client.runtime()
            return
        } catch (_: Throwable) {
            Thread.sleep(250)
        }
    }
    throw CliError("timed out waiting for the Reticle runtime; is the agent linked into the app?")
}

private fun defaultSerial(): String? {
    val devices = Adb().listDevices()
    return devices.singleOrNull()
}

private fun pickHostPort(devicePort: Int): Int = devicePort

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
        ui report    --package <pkg> [--output <dir>]
        ui tree      <snapshot.json> [--accessibility] [--depth N]
        ui compact   <snapshot.json>
        ui node      <snapshot.json> (--test-id|--resource-id|--ref)
        ui regions   <snapshot.json>                 # sub-regions in single nodes
        act tap      --package <pkg> (--test-id|--resource-id|--ref|--point x,y) [--region "substr"]
        act swipe    --package <pkg> --from x,y --to x,y [--duration ms]
        act drag     --package <pkg> --from x,y --to x,y [--duration ms]
        act type     --package <pkg> --text "..."
        debug logs   --package <pkg> [--output <file>]
        mutate       --package <pkg> (selector) --property <p> --value <v>
        doctor
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
