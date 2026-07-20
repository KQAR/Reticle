package dev.reticle.cli

import dev.reticle.cli.platform.DeviceController
import dev.reticle.core.PortMap
import dev.reticle.core.Point
import dev.reticle.core.RuntimeInfo
import dev.reticle.core.SemanticTree
import kotlinx.serialization.json.JsonObject

/**
 * Session-scoped record of the `adb forward`s the helper set up, so they can be
 * torn down when the helper exits. Forwards live on the (persistent) adb server,
 * which outlives the helper process, so without this they leak — one per distinct
 * package driven — and pile up across sessions. Idempotent per host port (the
 * port is derived deterministically from the package, so re-driving the same app
 * reuses one forward). Access is single-threaded: the helper serves RPC lines
 * sequentially and cleanup runs after that loop.
 */
internal object ForwardRegistry {
    private val forwards = LinkedHashMap<Int, DeviceController>()

    fun record(device: DeviceController, hostPort: Int) {
        forwards[hostPort] = device
    }

    /** Best-effort removal of every forward set up this session. */
    fun cleanup() {
        for ((hostPort, device) in forwards) {
            runCatching { device.removeForward(hostPort) }
        }
        forwards.clear()
    }
}

/** Runtime connection helpers shared by helper RPC command handlers. */
internal fun runtimeClientFor(
    device: DeviceController,
    pkg: String,
    params: JsonObject,
): RuntimeClient {
    val devicePort = params.intOrNull("port") ?: PortMap.derivePort(pkg)
    val hostPort = params.intOrNull("hostPort") ?: devicePort
    return RuntimeClient(device, hostPort, devicePort).also {
        it.setUpForward()
        ForwardRegistry.record(device, hostPort)
    }
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

internal fun resolveInputTarget(device: DeviceController, pkg: String, params: JsonObject): ResolvedInputTarget {
    params.str("alias")?.let { alias ->
        val entry = OutlineRenderer.resolveAlias(params.str("serial"), pkg, alias)
        val point = Point(entry.frame.centerX, entry.frame.centerY)
        return ResolvedInputTarget(point, "outline:$alias", entry.ref)
    }
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
