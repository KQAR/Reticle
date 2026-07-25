package dev.reticle.sample

import android.os.Bundle
import android.widget.Button
import androidx.activity.compose.setContent
import androidx.appcompat.app.AppCompatActivity
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import dev.reticle.agent.Reticle
import androidx.compose.material3.Button as M3Button

/**
 * The Compose surface. Reticle synthesizes no view per composable — a composable
 * is addressable only through the `SemanticsNode` tree that also backs platform
 * accessibility (`Modifier.testTag`, `contentDescription`), which the agent reads
 * reflectively. That bridge shipped without a single scenario, so this screen is
 * the case that exercises it, one composable per shape that matters:
 *
 *  - a tagged button and a status `Text` (does a testTag resolve, and does the
 *    state change show up in the next capture);
 *  - a tagged `TextField` (`act type` into a composable, not a `View`);
 *  - an annotated-string link (`LinkAnnotation`): a sub-region inside ONE text
 *    node, the Compose analogue of a `ClickableSpan` row;
 *  - a `Dialog`, which is its own window with its own Compose host;
 *  - an `AndroidView` interop child, a classic `View` living inside the Compose
 *    tree.
 */
class ComposeScenarioActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { ComposeScenarioScreen() }
        Reticle.log("compose_visible", mapOf("screen" to "compose"))
    }
}

@Composable
private fun ComposeScenarioScreen() {
    var status by remember { mutableStateOf("Idle") }
    var code by remember { mutableStateOf("") }
    var dialogVisible by remember { mutableStateOf(false) }

    MaterialTheme {
        Surface(modifier = Modifier.fillMaxSize()) {
            Column(modifier = Modifier.padding(24.dp)) {
                Text(text = status, modifier = Modifier.testTag("compose.status"))

                M3Button(
                    onClick = {
                        status = "Paid!"
                        Reticle.log("compose_paid", mapOf("via" to "testTag"))
                    },
                    modifier = Modifier.testTag("compose.payButton"),
                ) { Text("Pay now") }

                TextField(
                    value = code,
                    onValueChange = {
                        code = it
                        status = "Code: $it"
                    },
                    modifier = Modifier.testTag("compose.codeField"),
                )

                Text(
                    text = agreementText { link ->
                        status = "opened $link"
                        Reticle.log("compose_link_clicked", mapOf("link" to link))
                    },
                    modifier = Modifier.testTag("compose.agreement"),
                )

                M3Button(
                    onClick = { dialogVisible = true },
                    modifier = Modifier.testTag("compose.dialogTrigger"),
                ) { Text("Show Compose dialog") }

                // Interop: a classic View inside the Compose tree. Its testId comes
                // from the View tag, not from a semantics tag.
                AndroidView(
                    factory = { context ->
                        Button(context).apply {
                            tag = "compose.interopButton"
                            text = "Interop button"
                            setOnClickListener {
                                status = "Interop tapped"
                                Reticle.log("compose_interop_tapped", emptyMap())
                            }
                        }
                    },
                    modifier = Modifier.testTag("compose.interopHost"),
                )
            }
        }
    }

    if (dialogVisible) {
        Dialog(onDismissRequest = { dialogVisible = false }) {
            Surface {
                Column(modifier = Modifier.padding(24.dp)) {
                    Text("Confirm payment?", modifier = Modifier.testTag("composeDialog.title"))
                    M3Button(
                        onClick = {
                            status = "Confirmed"
                            dialogVisible = false
                            Reticle.log("compose_dialog_confirmed", emptyMap())
                        },
                        modifier = Modifier.testTag("composeDialog.confirm"),
                    ) { Text("Confirm") }
                }
            }
        }
    }
}

/**
 * One text node with an embedded link — the Compose analogue of the agreement row
 * that motivated the region channels. The link is a real `LinkAnnotation`, i.e.
 * the framework-sanctioned form, not a manually hit-tested phrase.
 */
private fun agreementText(onLink: (String) -> Unit): AnnotatedString = buildAnnotatedString {
    append("I agree to the ")
    withLink(
        LinkAnnotation.Clickable(
            tag = "terms",
            styles = TextLinkStyles(style = androidx.compose.ui.text.SpanStyle(textDecoration = TextDecoration.Underline)),
        ) { onLink("Terms") }
    ) { append("Terms") }
    append(" and ")
    withLink(
        LinkAnnotation.Clickable(
            tag = "privacy",
            styles = TextLinkStyles(style = androidx.compose.ui.text.SpanStyle(textDecoration = TextDecoration.Underline)),
        ) { onLink("Privacy") }
    ) { append("Privacy") }
}
