package dev.reticle.cli

import dev.reticle.cli.platform.DeviceController
import dev.reticle.core.PortMap
import dev.reticle.core.Point
import dev.reticle.core.RuntimeInfo
import dev.reticle.core.SemanticTree
import kotlinx.serialization.json.JsonObject

/** Runtime connection helpers shared by helper RPC command handlers. */
internal fun runtimeClientFor(
    device: DeviceController,
    pkg: String,
    params: JsonObject,
): RuntimeClient {
    val devicePort = params.intOrNull("port") ?: PortMap.derivePort(pkg)
    val hostPort = params.intOrNull("hostPort") ?: devicePort
    return RuntimeClient(device, hostPort, devicePort).also { it.setUpForward() }
}

internal fun assertHealthy(client: RuntimeClient, pkg: String) {
    when (val h = client.probe()) {
        is RuntimeHealth.Healthy -> if (h.info.packageName != pkg) {
            throw CliError("port conflict: served by '${h.info.packageName}', not '$pkg'")
        }
        is RuntimeHealth.Unreachable ->
            throw CliError("no Reticle runtime for '$pkg' (connection refused). Inject or launch first.")
        is RuntimeHealth.Unresponsive ->
            throw CliError("runtime for '$pkg' connected but did not respond (${h.detail})")
        is RuntimeHealth.Foreign ->
            throw CliError("port answered but not as a Reticle runtime (${h.sample})")
    }
}

/** Poll /runtime until the agent for [pkg] answers healthy, else throw. */
internal fun awaitRuntime(client: RuntimeClient, pkg: String, attempts: Int = 40): RuntimeInfo {
    repeat(attempts) {
        when (val health = client.probe()) {
            is RuntimeHealth.Healthy -> if (health.info.packageName == pkg) return health.info
            else -> {}
        }
        Thread.sleep(250)
    }
    throw CliError("timed out waiting for the runtime of '$pkg' to come up after inject")
}

/** A selector or raw point resolved to the exact screen coordinate adb will tap. */
internal data class ResolvedInputTarget(
    val point: Point,
    val source: String,
    val ref: String?,
)

internal fun resolvePoint(device: DeviceController, pkg: String, params: JsonObject): Pair<Int, Int> {
    val resolved = resolveInputTarget(device, pkg, params)
    return resolved.point.x.toInt() to resolved.point.y.toInt()
}

internal fun resolveInputTarget(device: DeviceController, pkg: String, params: JsonObject): ResolvedInputTarget {
    params.str("point")?.let {
        val (x, y) = parseXY(it)
        return ResolvedInputTarget(Point(x.toDouble(), y.toDouble()), "point", null)
    }
    val client = runtimeClientFor(device, pkg, params)
    assertHealthy(client, pkg)
    val snapshot = client.snapshot()
    val semantic = SemanticTree.build(snapshot)
    val selector = selectorFrom(params)
    val resolved = SelectorResolver(snapshot, semantic).resolve(selector)
        ?: throw CliError(SelectorDiagnostics.pointMiss(snapshot, selector))
    System.err.println("reticle-helper: resolved via ${resolved.source} -> ref=${resolved.ref}")
    return ResolvedInputTarget(resolved.point, resolved.source, resolved.ref)
}
