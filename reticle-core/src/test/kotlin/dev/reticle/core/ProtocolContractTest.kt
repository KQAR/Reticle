package dev.reticle.core

import com.networknt.schema.JsonSchema
import com.networknt.schema.JsonSchemaFactory
import com.networknt.schema.SpecVersion
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * The protocol contract: the JSON Schema under reticle-protocol/schema is the
 * authoritative, language-neutral wire spec. The Kotlin types in reticle-core
 * are ONE implementation of it. This test pins both directions so they can never
 * silently drift:
 *
 *   1. the checked-in golden fixture validates against the schema (the fixture
 *      is the cross-platform example every implementation must reproduce);
 *   2. JSON that the Kotlin model emits validates against the schema (Kotlin
 *      conforms to the spec);
 *   3. the golden fixture deserializes back through the Kotlin model and
 *      re-serializes to the same JSON (Kotlin can consume the spec's example
 *      losslessly).
 *
 * Schema + fixtures are mounted as test resources via reticle-core/build.gradle.kts
 * (srcDir reticle-protocol/), so this test reads them off the classpath.
 */
class ProtocolContractTest {

    private fun resource(path: String): String =
        javaClass.classLoader.getResourceAsStream(path)?.bufferedReader()?.readText()
            ?: fail("missing test resource on classpath: $path (is reticle-protocol/ mounted as a test resource?)")

    private fun schema(path: String): JsonSchema {
        val factory = JsonSchemaFactory.getInstance(SpecVersion.VersionFlag.V202012)
        return factory.getSchema(resource(path))
    }

    private fun snapshotSchema(): JsonSchema = schema("schema/snapshot.schema.json")

    private fun eventSchema(): JsonSchema = schema("schema/event.schema.json")

    private fun networkPayloadSchema(): JsonSchema = schema("schema/network-event-payload.schema.json")

    private fun assertValid(schema: JsonSchema, json: String, label: String) {
        val mapper = com.fasterxml.jackson.databind.ObjectMapper()
        val node = mapper.readTree(json)
        val errors = schema.validate(node)
        if (errors.isNotEmpty()) {
            fail("$label did not satisfy its schema:\n" +
                errors.joinToString("\n") { "  - $it" })
        }
    }

    @Test
    fun goldenFixtureSatisfiesSchema() {
        assertValid(snapshotSchema(), resource("fixtures/snapshot.golden.json"), "golden fixture")
    }

    @Test
    fun iosGoldenFixtureSatisfiesSchema() {
        // The iOS agent (reticle-agent/ios) is a separate Swift implementation of
        // this same schema; pin its wire shape here so an Android-only change that
        // narrows the contract (e.g. dropping the axElement NodeKind) fails CI.
        val ios = resource("fixtures/ios-snapshot.golden.json")
        assertValid(snapshotSchema(), ios, "iOS golden fixture")
        // Also decodes through the Kotlin model losslessly and re-satisfies the schema.
        val decoded = ReticleJson.instance.decodeFromString(Snapshot.serializer(), ios)
        assertEquals("ios", decoded.platform)
        assertEquals(NodeKind.axElement, decoded.nodes.getValue("r3").kind)
        val reencoded = ReticleJson.instance.encodeToString(Snapshot.serializer(), decoded)
        assertValid(snapshotSchema(), reencoded, "re-encoded iOS golden fixture")
    }

    @Test
    fun kotlinEmittedJsonSatisfiesSchema() {
        val snapshot = sampleSnapshot()
        val json = ReticleJson.instance.encodeToString(Snapshot.serializer(), snapshot)
        assertValid(snapshotSchema(), json, "Kotlin-emitted snapshot")
    }

    @Test
    fun goldenFixtureRoundTripsThroughKotlin() {
        val golden = resource("fixtures/snapshot.golden.json")
        val decoded = ReticleJson.instance.decodeFromString(Snapshot.serializer(), golden)
        // Spot-check the parts that exercise the tricky shapes (discriminated
        // MetadataValue, nested regions, char grid) rather than trusting a blind
        // string compare against hand-authored whitespace.
        assertEquals("r0", decoded.rootRef)
        assertEquals(
            KeyboardInfo(visible = true, frame = Rect(0.0, 2000.0, 1080.0, 400.0)),
            decoded.screen.keyboard,
        )
        val row = decoded.nodes.getValue("r1")
        assertEquals(MetadataValue.Real(1.0), row.custom["alpha"])
        assertEquals(MetadataValue.Text("#FF202124"), row.custom["textColor"])
        assertEquals(MetadataValue.Integer(1L), row.custom["lineCount"])
        assertEquals(2, row.regions.size)
        assertEquals(RegionSource.span, row.regions[0].source)
        assertEquals("Terms", row.regions[0].label)
        assertTrue(row.charGrid != null && row.charGrid!!.lines.size == 1)
        val dom = decoded.nodes.getValue("r2")
        assertEquals(NodeKind.domNode, dom.kind)
        assertEquals(MetadataValue.Text("#web-pay"), dom.custom["domCssSelector"])

        // And re-serializing the decoded model must itself satisfy the schema.
        val reencoded = ReticleJson.instance.encodeToString(Snapshot.serializer(), decoded)
        assertValid(snapshotSchema(), reencoded, "re-encoded golden fixture")
    }

    @Test
    fun kotlinSchemaVersionMatchesSchemaConst() {
        // The code's SCHEMA_VERSION and the schema's `const` must agree, or the
        // "single source of truth" claim is false. Read the const out of the
        // schema file and compare.
        val mapper = com.fasterxml.jackson.databind.ObjectMapper()
        val schemaNode = mapper.readTree(resource("schema/snapshot.schema.json"))
        val declared = schemaNode.get("properties").get("schemaVersion").get("const").asInt()
        assertEquals(declared, Snapshot.SCHEMA_VERSION, "Snapshot.SCHEMA_VERSION vs schema const")
        assertEquals(declared, Snapshot(capturedAtMillis = 0, screen = ScreenInfo(Size(1.0, 1.0), 1.0), rootRef = "r0", nodes = emptyMap()).schemaVersion)
    }

    @Test
    fun eventGoldenFixturesSatisfyEventSchema() {
        // The daemon event envelope has its own authoritative schema; validate the
        // checked-in golden fixtures against it so they can't silently drift.
        assertValid(eventSchema(), resource("fixtures/action-trace-event.golden.json"), "action-trace event fixture")
        assertValid(eventSchema(), resource("fixtures/network-request-event.golden.json"), "network-request event fixture")
        assertValid(eventSchema(), resource("fixtures/network-response-event.golden.json"), "network-response event fixture")
        assertValid(eventSchema(), resource("fixtures/network-error-event.golden.json"), "network-error event fixture")
    }

    @Test
    fun networkFixturePayloadsSatisfyTypedPayloadSchema() {
        // The event envelope leaves `payload` open; the proxy `network.*` payload
        // has its own typed schema. Validate each fixture's payload against it so
        // the host emitter and any consumer share one pinned shape.
        val mapper = com.fasterxml.jackson.databind.ObjectMapper()
        val schema = networkPayloadSchema()
        for (name in listOf(
            "network-request-event.golden.json",
            "network-response-event.golden.json",
            "network-error-event.golden.json"
        )) {
            val payload = mapper.readTree(resource("fixtures/$name")).get("payload")
            val errors = schema.validate(payload)
            if (errors.isNotEmpty()) {
                fail("$name payload did not satisfy the network payload schema:\n" +
                    errors.joinToString("\n") { "  - $it" })
            }
        }
    }

    private fun sampleSnapshot(): Snapshot = Snapshot(
        capturedAtMillis = 1719400000000L,
        screen = ScreenInfo(
            size = Size(1080.0, 2400.0),
            density = 3.0,
            interfaceStyle = "dark",
            keyboard = KeyboardInfo(visible = true, frame = Rect(0.0, 2000.0, 1080.0, 400.0)),
        ),
        rootRef = "r0",
        nodes = mapOf(
            "r0" to Node(
                ref = "r0",
                kind = NodeKind.application,
                typeName = "android.app.Application",
                role = "application",
                children = listOf("r1", "r2"),
            ),
            "r1" to Node(
                ref = "r1",
                parentRef = "r0",
                kind = NodeKind.view,
                typeName = "android.widget.TextView",
                role = "text",
                resourceId = "agreement_row",
                text = "I agree to the Terms and Privacy",
                testId = "agreement",
                frame = Rect(24.0, 1800.0, 1032.0, 120.0),
                isInteractive = true,
                custom = mapOf(
                    "alpha" to MetadataValue.Real(1.0),
                    "textColor" to MetadataValue.Text("#FF202124"),
                    "lineCount" to MetadataValue.Integer(1L),
                    "selected" to MetadataValue.Bool(false),
                ),
                regions = listOf(
                    InteractionRegion(
                        source = RegionSource.span,
                        label = "Terms",
                        target = "https://example.com/terms",
                        charStart = 15,
                        charEnd = 20,
                        rects = listOf(Rect(430.0, 1800.0, 120.0, 60.0)),
                        color = "#FF1A73E8",
                    ),
                ),
                charGrid = CharGrid(
                    text = "Terms",
                    lines = listOf(
                        CharLine(line = 0, start = 0, end = 5, top = 1800.0, bottom = 1860.0,
                            xOffsets = listOf(430.0, 454.0, 478.0, 502.0, 526.0, 550.0)),
                    ),
                ),
            ),
            "r2" to Node(
                ref = "r2",
                parentRef = "r0",
                kind = NodeKind.domNode,
                typeName = "DOMElement",
                role = "button",
                text = "Pay in WebView",
                testId = "web.payButton",
                frame = Rect(100.0, 300.0, 240.0, 72.0),
                isInteractive = true,
                custom = mapOf(
                    "domCssSelector" to MetadataValue.Text("#web-pay"),
                    "domTag" to MetadataValue.Text("button"),
                ),
            ),
        ),
    )
}
