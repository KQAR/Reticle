package dev.reticle.cli

import dev.reticle.core.MetadataValue
import dev.reticle.core.Node

/**
 * The DOM CSS selector a WebView-backed node was captured with, if any. Stored
 * as a scalar custom property by the agent; read the same way everywhere so the
 * key/cast lives in exactly one place.
 */
internal fun Node.domCssSelector(): String? =
    (custom["domCssSelector"] as? MetadataValue.Text)?.value
