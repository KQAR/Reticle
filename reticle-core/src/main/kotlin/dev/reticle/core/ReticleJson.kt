package dev.reticle.core

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.json.Json

/**
 * Shared JSON configuration used across the CLI and agent.
 *
 * Both instances omit null fields (`explicitNulls = false`) and fields whose
 * value equals their default (`encodeDefaults = false`), so a snapshot only
 * carries the fields that actually mean something. This is lossless: a dropped
 * field decodes back to the same default, and any non-default value is always
 * emitted. Schema-`required` fields that happen to have a Kotlin default
 * (`Snapshot.schemaVersion`, `Snapshot.platform`) are pinned with
 * `@EncodeDefault(ALWAYS)` so they survive the omission.
 *
 * [instance] is pretty-printed for human-readable on-disk artifacts
 * (`snapshot.json`, `trace.json`, `ui node` output); [compact] is minified for
 * the wire — the agent's HTTP responses and helper RPC assembly.
 */
@OptIn(ExperimentalSerializationApi::class)
object ReticleJson {
    val instance: Json = Json {
        prettyPrint = true
        prettyPrintIndent = "  "
        encodeDefaults = false
        explicitNulls = false
        ignoreUnknownKeys = true
        classDiscriminator = "_type"
    }

    val compact: Json = Json {
        prettyPrint = false
        encodeDefaults = false
        explicitNulls = false
        ignoreUnknownKeys = true
        classDiscriminator = "_type"
    }
}
