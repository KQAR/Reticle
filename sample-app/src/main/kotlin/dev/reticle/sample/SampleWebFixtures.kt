package dev.reticle.sample

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.view.ViewGroup
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.LinearLayout

/**
 * WebView fixtures used to exercise Reticle's read-only DOM bridge.
 *
 * The basic fixture stays small for old smoke paths. The complex fixture backs
 * the dedicated WebView scenario so DOM style, image, selector, and layout
 * metadata are visible without cluttering the sample home screen.
 */
object SampleWebFixtures {
    const val EXTRA_WEB_URL = "reticle.webUrl"
    const val EXTRA_WEB_SCENARIO = "reticle.webScenario"

    private const val SCENARIO_COMPLEX = "complex"

    data class Fixture(
        val heightPx: Int,
        val baseUrl: String,
        val html: String? = null,
        val remoteUrl: String? = null,
    )

    fun resolve(intent: Intent): Fixture {
        val remoteWebUrl = intent.getStringExtra(EXTRA_WEB_URL)?.takeIf(::isAllowedWebTestUrl)
        if (remoteWebUrl != null) {
            return Fixture(heightPx = 900, baseUrl = remoteWebUrl, remoteUrl = remoteWebUrl)
        }
        return when (intent.getStringExtra(EXTRA_WEB_SCENARIO)) {
            SCENARIO_COMPLEX -> complexFixture(heightPx = 900)
            else -> basicFixture(heightPx = 280)
        }
    }

    fun createWebView(context: Context): WebView =
        createWebView(context, complexFixture(heightPx = ViewGroup.LayoutParams.MATCH_PARENT))

    @SuppressLint("SetJavaScriptEnabled")
    fun createWebView(context: Context, fixture: Fixture): WebView =
        WebView(context).apply {
            tag = "checkout.webView"
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean = false
            }
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                fixture.heightPx,
            )
            if (fixture.remoteUrl != null) {
                loadUrl(fixture.remoteUrl)
            } else {
                loadDataWithBaseURL(fixture.baseUrl, fixture.html.orEmpty(), "text/html", "UTF-8", null)
            }
        }

    private fun basicFixture(heightPx: Int): Fixture =
        Fixture(
            heightPx = heightPx,
            baseUrl = "https://reticle.dev/sample/basic",
            html = basicCheckoutHtml,
        )

    private fun complexFixture(heightPx: Int): Fixture =
        Fixture(
            heightPx = heightPx,
            baseUrl = "https://reticle.dev/sample/complex",
            html = complexHtml,
        )

    private fun isAllowedWebTestUrl(url: String): Boolean =
        url.startsWith("https://") ||
            url.startsWith("http://127.0.0.1") ||
            url.startsWith("http://localhost")

    private val basicCheckoutHtml: String = """
        <!doctype html>
        <html>
          <body style="margin:0;font-family:sans-serif">
            <section id="web-checkout" aria-label="Web checkout">
              <p id="web-status" data-testid="web.status">Web cart ready</p>
              <button id="web-pay" data-testid="web.payButton"
                onclick="document.getElementById('web-status').innerText='Web paid'">
                Pay in WebView
              </button>
            </section>
          </body>
        </html>
    """.trimIndent()

    private val complexHtml: String = """
        <!doctype html>
        <html>
          <head>
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <style>
              body { font-family: sans-serif; margin: 16px; }
              section { margin: 14px 0; }
              #fixed-cta { position: fixed; right: 12px; bottom: 12px; z-index: 2; }
              #spacer { height: 1300px; background: linear-gradient(#fff, #eef); }
              #scaled-button { transform: scale(1.2); transform-origin: left top; margin: 24px; }
              #style-target {
                width: 120px;
                height: 44px;
                margin: 12px 24px 8px 16px;
                padding: 6px 10px 8px 12px;
                border: 2px solid #1A73E8;
                border-radius: 10px;
                background: rgb(232, 240, 254);
                color: rgb(26, 115, 232);
                font-size: 14px;
                font-weight: 600;
                line-height: 18px;
                text-align: center;
                opacity: 0.88;
                pointer-events: auto;
              }
              #style-target.promoted {
                border-width: 4px;
                background: rgb(26, 115, 232);
                color: rgb(255, 255, 255);
                opacity: 1;
              }
              #photo-img { width: 96px; height: 64px; object-fit: contain; margin: 10px; }
              #background-card {
                width: 140px;
                height: 72px;
                background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='64' height='32'%3E%3Crect width='64' height='32' fill='%23fbbc04'/%3E%3C/svg%3E");
                background-size: cover;
              }
              #shadow-host { display: block; width: 240px; height: 72px; border: 1px solid #ccc; }
              #hidden-display { display: none; }
              #hidden-visibility { visibility: hidden; }
            </style>
          </head>
          <body>
            <h1 id="complex-title" data-testid="complex.title">Reticle complex web fixture</h1>
            <p id="dynamic-status">Loading dynamic content...</p>

            <section id="forms">
              <input id="filled-input" data-testid="complex.filledInput" value="Ada">
              <textarea id="notes-field" data-testid="complex.notesField">Initial note</textarea>
              <select id="plan-select" data-testid="complex.planSelect">
                <option>Basic</option>
                <option selected>Pro</option>
              </select>
              <button id="echo-name" data-testid="complex.echoButton"
                onclick="document.getElementById('echo-output').innerText='Echo: '+document.getElementById('filled-input').value">
                Echo name
              </button>
              <p id="echo-output" data-testid="complex.echoOutput">Echo: empty</p>
            </section>

            <section id="interactions">
              <button id="disabled-button" data-testid="complex.disabledButton" disabled>Disabled action</button>
              <button id="aria-disabled-button" data-testid="complex.ariaDisabledButton" aria-disabled="true">ARIA disabled</button>
              <div id="role-button" data-testid="complex.roleButton" role="button" tabindex="0"
                onclick="this.innerText='Role clicked'">
                Role button
              </div>
              <div id="editable" data-testid="complex.editable" contenteditable="true">Editable text</div>
              <a id="anchor-link" data-testid="complex.anchorLink" href="#scroll-target">Jump to scroll target</a>
              <button id="web-evidence" data-testid="complex.webEvidence"
                onclick="console.log('evidence button clicked'); fetch('data:text/plain,ok');">
                Emit web evidence
              </button>
              <button class="generated-selector" data-testid="complex.generatedSelector"
                onclick="this.innerText='Generated clicked'">
                Generated selector
              </button>
            </section>

            <section id="boundaries">
              <div id="shadow-host" data-testid="complex.shadowHost">Shadow host</div>
              <iframe id="fixture-frame" data-testid="complex.iframe"
                srcdoc="<button id='iframe-button' data-testid='complex.iframeButton'>Inside frame</button>">
              </iframe>
              <p id="hidden-display">Hidden by display</p>
              <p id="hidden-visibility">Hidden by visibility</p>
            </section>

            <section id="layout">
              <button id="scaled-button" data-testid="complex.scaledButton"
                onclick="this.innerText='Scaled clicked'">
                Scaled button
              </button>
              <button id="style-target" data-testid="complex.styleTarget" aria-label="Style target"
                onclick="this.innerText='Style changed'; this.className='promoted'; this.setAttribute('aria-label','Promoted style target'); this.style.width='180px'; this.style.height='56px'; this.style.marginLeft='40px'; this.style.paddingLeft='20px'; this.style.borderRadius='18px'">
                Style target
              </button>
              <svg id="logo-svg" data-testid="complex.svg" role="img" aria-label="Vector mark"
                width="120" height="48">
                <rect width="120" height="48" fill="#1A73E8"></rect>
                <text x="12" y="30" fill="white">SVG</text>
              </svg>
              <canvas id="chart-canvas" data-testid="complex.canvas" title="Chart canvas"
                width="160" height="60"></canvas>
              <img id="photo-img" data-testid="complex.photo"
                alt="Inline SVG photo"
                src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='48' height='32'%3E%3Crect width='48' height='32' fill='%2334a853'/%3E%3Ctext x='6' y='21' fill='white'%3EIMG%3C/text%3E%3C/svg%3E">
              <div id="background-card" data-testid="complex.backgroundImage" title="Background image card"></div>
            </section>

            <button id="fixed-cta" data-testid="complex.fixedCta"
              onclick="this.innerText='Fixed clicked'">
              Fixed CTA
            </button>
            <div id="spacer">Scroll down through page content</div>
            <button id="scroll-target" data-testid="complex.scrollTarget"
              onclick="this.innerText='Scrolled clicked'">
              Scroll target
            </button>

            <script>
              setTimeout(function() {
                document.getElementById('dynamic-status').innerText = 'Dynamic content ready';
              }, 300);
              var root = document.getElementById('shadow-host').attachShadow({ mode: 'open' });
              root.innerHTML = '<button id="shadow-button" data-testid="complex.shadowButton">Shadow action</button>';
              var canvas = document.getElementById('chart-canvas');
              var ctx = canvas.getContext('2d');
              ctx.fillStyle = '#34A853';
              ctx.fillRect(0, 0, 160, 60);
            </script>
          </body>
        </html>
    """.trimIndent()
}
