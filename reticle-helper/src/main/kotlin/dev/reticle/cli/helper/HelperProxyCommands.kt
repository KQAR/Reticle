package dev.reticle.cli

import dev.reticle.cli.platform.Platforms
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Android global proxy helpers used by `reticle serve --proxy-device`. */
internal object HelperProxyCommands {
    fun status(params: JsonObject): JsonElement {
        val device = Platforms.current().device(params.str("serial"))
        device.ensureDeviceReady()
        return buildJsonObject { put("httpProxy", readProxy(device)) }
    }

    fun set(params: JsonObject): JsonElement {
        val device = Platforms.current().device(params.str("serial"))
        device.ensureDeviceReady()
        val previous = readProxy(device)
        val value = params.str("value") ?: proxyValue(params)
        validateProxyValue(value)
        val port = value.substringAfterLast(":").toIntOrNull()
        if (value.startsWith("127.0.0.1:") && port != null) {
            val reverse = device.run("reverse", "tcp:$port", "tcp:$port")
            if (!reverse.ok) throw CliError("failed to configure adb reverse: ${reverse.stderr.ifBlank { reverse.stdout }}")
        }
        val set = device.shell("settings put global http_proxy $value")
        if (!set.ok) throw CliError("failed to set device proxy: ${set.stderr.ifBlank { set.stdout }}")
        return buildJsonObject {
            put("previous", previous)
            put("current", value)
        }
    }

    fun clear(params: JsonObject): JsonElement {
        val device = Platforms.current().device(params.str("serial"))
        device.ensureDeviceReady()
        val previous = readProxy(device)
        params.intOrNull("port")?.let { device.run("reverse", "--remove", "tcp:$it") }
        val clear = device.shell("settings put global http_proxy :0")
        if (!clear.ok) throw CliError("failed to clear device proxy: ${clear.stderr.ifBlank { clear.stdout }}")
        return buildJsonObject {
            put("previous", previous)
            put("current", "")
        }
    }

    fun installCa(params: JsonObject): JsonElement {
        val device = Platforms.current().device(params.str("serial"))
        device.ensureDeviceReady()
        val path = params.str("path") ?: throw CliError("proxyInstallCa needs 'path'")
        val name = (params.str("name") ?: "Reticle_CA").replace(Regex("""[^A-Za-z0-9_.-]"""), "_")
        val remote = "/sdcard/Download/reticle-ca.cer"
        val push = device.run("push", path, remote)
        if (!push.ok) throw CliError("failed to push CA certificate: ${push.stderr.ifBlank { push.stdout }}")
        val settings = device.shell("am start -a android.settings.SECURITY_SETTINGS")
        val started = if (settings.ok) "android.settings.SECURITY_SETTINGS" else "manual"
        return buildJsonObject {
            put("path", remote)
            put("name", name)
            put("started", started)
            put("message", "Install the CA from Settings using the copied certificate file.")
        }
    }

    private fun proxyValue(params: JsonObject): String {
        val host = params.str("host") ?: "127.0.0.1"
        val port = params.intOrNull("port") ?: throw CliError("proxySet needs 'port'")
        if (port !in 1..65535) throw CliError("proxy port out of range: $port")
        return "$host:$port"
    }

    private fun readProxy(device: dev.reticle.cli.platform.DeviceController): String {
        val result = device.shell("settings get global http_proxy")
        if (!result.ok) return ""
        val value = result.stdout.trim()
        return if (value == "null" || value == ":0") "" else value
    }

    internal fun validateProxyValue(value: String) {
        val ok = Regex("""^[A-Za-z0-9._:-]+$""").matches(value) && value.contains(":")
        if (!ok) throw CliError("unsafe proxy value: $value")
    }
}
