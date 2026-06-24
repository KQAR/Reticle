package dev.reticle.core

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.json.Json

/** Shared JSON configuration used across the CLI and agent. */
@OptIn(ExperimentalSerializationApi::class)
object ReticleJson {
    val instance: Json = Json {
        prettyPrint = true
        prettyPrintIndent = "  "
        encodeDefaults = true
        ignoreUnknownKeys = true
        classDiscriminator = "_type"
    }

    val compact: Json = Json {
        prettyPrint = false
        encodeDefaults = true
        ignoreUnknownKeys = true
        classDiscriminator = "_type"
    }
}
