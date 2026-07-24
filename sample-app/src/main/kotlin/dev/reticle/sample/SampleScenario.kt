package dev.reticle.sample

import android.content.Context
import android.content.Intent
import androidx.appcompat.app.AppCompatActivity

/** Top-level sample scenarios shown on the home list. */
enum class SampleScenario(
    val title: String,
    val subtitle: String,
    val testId: String,
    private val activityClass: Class<out AppCompatActivity>,
) {
    Checkout(
        title = "Checkout controls",
        subtitle = "Button tap, status mutation, text input, and app logs",
        testId = "scenario.checkout",
        activityClass = CheckoutScenarioActivity::class.java,
    ),
    Agreements(
        title = "Agreement regions",
        subtitle = "ClickableSpan, text markers, char grid, and color spans",
        testId = "scenario.agreements",
        activityClass = AgreementScenarioActivity::class.java,
    ),
    WebView(
        title = "WebView DOM",
        subtitle = "Native title bar with a full-screen WebView underneath",
        testId = "scenario.webview",
        activityClass = WebViewScenarioActivity::class.java,
    ),
    Login(
        title = "Login keyboard trap",
        subtitle = "Bottom submit button that the soft keyboard covers",
        testId = "scenario.login",
        activityClass = LoginScenarioActivity::class.java,
    ),
    SystemDialog(
        title = "System dialog",
        subtitle = "AlertDialog window raised over the activity",
        testId = "scenario.dialog",
        activityClass = SystemDialogScenarioActivity::class.java,
    );

    fun intent(context: Context): Intent = Intent(context, activityClass)
}
