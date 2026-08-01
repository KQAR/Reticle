package dev.reticle.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * The ingestion gate for snapshots produced by a NEWER build. The decoder
 * ignores unknown keys by design, so without the gate a v2 producer's renamed
 * field silently decodes into a default and the projection presents invented
 * evidence as real — the exact silent failure `schemaVersion` was added to
 * prevent, except nothing ever read it.
 */
class SchemaVersionGateTest {

    private fun snapshotJson(version: Int) = """
        {
          "schemaVersion": $version,
          "capturedAtMillis": 0,
          "platform": "android",
          "screen": {"size": {"width": 400.0, "height": 900.0}, "density": 3.0},
          "rootRef": "r0",
          "nodes": {"r0": {"ref": "r0", "kind": "application", "typeName": "App"}}
        }
    """.trimIndent()

    private fun decode(version: Int): Snapshot =
        ReticleJson.instance.decodeFromString(Snapshot.serializer(), snapshotJson(version))

    @Test
    fun theCurrentVersionPassesTheGate() {
        assertEquals("r0", decode(Snapshot.SCHEMA_VERSION).requireSupportedSchema().rootRef)
    }

    @Test
    fun aNewerVersionIsRefusedByName() {
        val failure = assertFailsWith<UnsupportedSnapshotSchema> {
            decode(Snapshot.SCHEMA_VERSION + 1).requireSupportedSchema()
        }
        assertTrue(
            failure.message!!.contains("schemaVersion=${Snapshot.SCHEMA_VERSION + 1}"),
            "the refusal must name the version it saw: ${failure.message}"
        )
    }
}
