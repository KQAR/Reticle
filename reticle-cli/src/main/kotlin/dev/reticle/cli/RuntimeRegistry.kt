package dev.reticle.cli

import java.io.File
import java.util.Properties

/**
 * Persists serial+package -> (hostPort, devicePort) mappings under
 * ~/.reticle/runtimes so later commands can omit --host and just pass --package.
 */
object RuntimeRegistry {

    data class Record(
        val serial: String,
        val packageName: String,
        val hostPort: Int,
        val devicePort: Int,
    )

    private val dir: File by lazy {
        File(System.getProperty("user.home"), ".reticle/runtimes").apply { mkdirs() }
    }

    private fun fileFor(serial: String, packageName: String): File {
        val safe = "${serial}_${packageName}".replace(Regex("[^A-Za-z0-9._-]"), "_")
        return File(dir, "$safe.properties")
    }

    fun store(record: Record) {
        val props = Properties()
        props["serial"] = record.serial
        props["packageName"] = record.packageName
        props["hostPort"] = record.hostPort.toString()
        props["devicePort"] = record.devicePort.toString()
        fileFor(record.serial, record.packageName).outputStream().use {
            props.store(it, "reticle runtime")
        }
    }

    fun load(serial: String, packageName: String): Record? {
        val file = fileFor(serial, packageName)
        if (!file.exists()) return null
        val props = Properties()
        file.inputStream().use { props.load(it) }
        return Record(
            serial = props.getProperty("serial") ?: return null,
            packageName = props.getProperty("packageName") ?: return null,
            hostPort = props.getProperty("hostPort")?.toIntOrNull() ?: return null,
            devicePort = props.getProperty("devicePort")?.toIntOrNull() ?: return null,
        )
    }

    fun all(): List<Record> =
        dir.listFiles { f -> f.extension == "properties" }?.mapNotNull { file ->
            val props = Properties()
            file.inputStream().use { props.load(it) }
            val serial = props.getProperty("serial") ?: return@mapNotNull null
            val pkg = props.getProperty("packageName") ?: return@mapNotNull null
            Record(
                serial = serial,
                packageName = pkg,
                hostPort = props.getProperty("hostPort")?.toIntOrNull() ?: return@mapNotNull null,
                devicePort = props.getProperty("devicePort")?.toIntOrNull() ?: return@mapNotNull null,
            )
        } ?: emptyList()
}
