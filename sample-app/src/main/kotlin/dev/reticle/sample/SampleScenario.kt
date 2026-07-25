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
    CanvasControl(
        title = "Canvas control regions",
        subtitle = "Virtual a11y sub-nodes and a touch-delegate hit rect",
        testId = "scenario.canvasControl",
        activityClass = CanvasControlScenarioActivity::class.java,
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
    ),
    LottieDialog(
        title = "Lottie dialog",
        subtitle = "Native dialog with a real Lottie animation view",
        testId = "scenario.lottieDialog",
        activityClass = LottieDialogScenarioActivity::class.java,
    ),
    WebLottieDialog(
        title = "Web Lottie dialog",
        subtitle = "lottie-web modal rendered inside a WebView",
        testId = "scenario.webLottieDialog",
        activityClass = WebLottieDialogScenarioActivity::class.java,
    ),
    WebComponentDialog(
        title = "Web component dialog",
        subtitle = "Custom-element modal with open shadow-root content",
        testId = "scenario.webComponentDialog",
        activityClass = WebComponentDialogScenarioActivity::class.java,
    ),
    LottieOnlyDialog(
        title = "Lottie-only dialog",
        subtitle = "Whole dialog (text + buttons) baked into one Lottie",
        testId = "scenario.lottieOnlyDialog",
        activityClass = LottieOnlyDialogScenarioActivity::class.java,
    );

    fun intent(context: Context): Intent = Intent(context, activityClass)
}
