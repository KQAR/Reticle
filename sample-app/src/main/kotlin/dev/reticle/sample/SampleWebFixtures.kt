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
    private const val SCENARIO_FORM = "form"
    private const val SCENARIO_SCALED = "scaled"

    data class Fixture(
        val heightPx: Int,
        val baseUrl: String,
        val html: String? = null,
        val remoteUrl: String? = null,
        /**
         * `WebView.setInitialScale` percent, when this fixture is deliberately
         * rendered at a zoom other than 1.
         *
         * The layout viewport (`window.innerWidth`) does NOT change under zoom —
         * only the visual one does — so a page-to-device scale derived from
         * `innerWidth` alone is wrong by exactly this factor, and wrong in a way
         * that produces plausible rectangles rather than an error.
         */
        val initialScalePercent: Int? = null,
    )

    fun resolve(intent: Intent): Fixture {
        val remoteWebUrl = intent.getStringExtra(EXTRA_WEB_URL)?.takeIf(::isAllowedWebTestUrl)
        if (remoteWebUrl != null) {
            return Fixture(heightPx = 900, baseUrl = remoteWebUrl, remoteUrl = remoteWebUrl)
        }
        return when (intent.getStringExtra(EXTRA_WEB_SCENARIO)) {
            SCENARIO_COMPLEX -> complexFixture(heightPx = 900)
            SCENARIO_FORM -> formFixture(heightPx = 900)
            SCENARIO_SCALED -> scaledFixture(heightPx = 900)
            else -> basicFixture(heightPx = 280)
        }
    }

    fun createWebView(context: Context): WebView =
        createWebView(context, complexFixture(heightPx = ViewGroup.LayoutParams.MATCH_PARENT))

    /** A modal built with `lottie-web` playing a real Lottie animation. */
    fun lottieDialogFixture(context: Context): Fixture =
        Fixture(
            heightPx = ViewGroup.LayoutParams.MATCH_PARENT,
            baseUrl = "https://reticle.dev/sample/web-lottie",
            html = webLottieHtml(readAsset(context, "lottie_light.min.js"), readAsset(context, "lottie_anim.json")),
        )

    /** A modal built as a Web Component (custom element + open shadow root). */
    fun webComponentDialogFixture(): Fixture =
        Fixture(
            heightPx = ViewGroup.LayoutParams.MATCH_PARENT,
            baseUrl = "https://reticle.dev/sample/web-component",
            html = webComponentHtml,
        )

    /** A page that raises a native JS modal (`alert()`), blocking the JS thread. */
    fun webJsDialogFixture(): Fixture =
        Fixture(
            heightPx = ViewGroup.LayoutParams.MATCH_PARENT,
            baseUrl = "https://reticle.dev/sample/web-js-dialog",
            html = webJsDialogHtml,
        )

    private fun readAsset(context: Context, name: String): String =
        context.assets.open(name).bufferedReader().use { it.readText() }

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
            fixture.initialScalePercent?.let(::setInitialScale)
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

    /**
     * The shape a form built out of framework components actually has, which the
     * complex fixture is the opposite of: every input there carries an id, a
     * `data-testid` AND a value, so it can never reproduce the screen that
     * motivated this — five inputs projecting as five identical `textField` lines
     * distinguishable only by y-coordinate.
     *
     * Nothing here sets an id or a `data-testid`. What each field DOES carry is
     * what such a form really carries: a `placeholder`, a `name`, and sometimes an
     * `aria-label`. Plus the input types whose role used to be flattened to
     * `textField`, a field that declares itself invalid and names its own error,
     * and a field that starts disabled.
     */
    fun formFixture(heightPx: Int): Fixture =
        Fixture(
            heightPx = heightPx,
            baseUrl = "https://reticle.dev/sample/form",
            html = formHtml,
        )

    /**
     * The same page rendered at a zoom other than 1 — the case every other web
     * fixture is blind to, because they all render at exactly 1:1 where a wrong
     * scale factor and a right one agree.
     *
     * A zoomed WebView keeps its LAYOUT viewport (`window.innerWidth`) and scales
     * only what is painted, so a frame derived from `frameWidth / innerWidth`
     * lands short of where the element actually is, by the zoom factor, growing
     * with distance from the origin. It never errors: the rect is plausible, the
     * tap "succeeds", and the flow silently does not advance.
     */
    fun scaledFixture(heightPx: Int): Fixture =
        Fixture(
            heightPx = heightPx,
            baseUrl = "https://reticle.dev/sample/scaled",
            html = scaledHtml,
            initialScalePercent = 130,
        )

    /** The host page of [NestedWebViewScenarioActivity], underneath the overlay. */
    fun nestedBackdropFixture(): Fixture =
        Fixture(
            heightPx = ViewGroup.LayoutParams.MATCH_PARENT,
            baseUrl = "https://reticle.dev/sample/nested-backdrop",
            html = nestedBackdropHtml,
        )

    /** The second web container, stacked over the backdrop at an offset. */
    fun nestedOverlayFixture(): Fixture =
        Fixture(
            heightPx = ViewGroup.LayoutParams.MATCH_PARENT,
            baseUrl = "https://reticle.dev/sample/nested-overlay",
            html = nestedOverlayHtml,
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
              #closed-shadow-host { display: block; width: 240px; height: 72px; border: 1px solid #ccc; }
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
              <!--
                The closed twin, for the boundary the open one hides: a `{mode:
                'closed'}` root gives the page itself no `shadowRoot` handle, so the
                traversal script cannot reach into it either. Its content must be
                ABSENT from the tree — asserted, so silence here is never mistaken
                for capture.
              -->
              <div id="closed-shadow-host" data-testid="complex.closedShadowHost">Closed shadow host</div>
              <!--
                A same-origin (srcdoc) frame. The button carries its own onclick so
                a COORDINATE tap can be told apart from one that merely dispatched:
                the frame's content coordinates are relative to the frame viewport,
                so a missing page offset puts the reported rect at the top of the
                page and the tap lands somewhere else entirely.
              -->
              <iframe id="fixture-frame" data-testid="complex.iframe"
                srcdoc="<button id='iframe-button' data-testid='complex.iframeButton'
                  onclick='this.innerText=&quot;Frame clicked&quot;'>Inside frame</button>">
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
              var closed = document.getElementById('closed-shadow-host').attachShadow({ mode: 'closed' });
              closed.innerHTML = '<button id="closed-shadow-button">Closed shadow action</button>';
              var canvas = document.getElementById('chart-canvas');
              var ctx = canvas.getContext('2d');
              ctx.fillStyle = '#34A853';
              ctx.fillRect(0, 0, 160, 60);
            </script>
          </body>
        </html>
    """.trimIndent()


    private val formHtml: String = """
        <!doctype html>
        <html>
          <head>
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <style>
              body { font-family: sans-serif; margin: 16px; }
              .row { margin: 14px 0; }
              input, select { display: block; width: 90%; padding: 8px; font-size: 15px; }
              .error { color: #d93025; font-size: 13px; }
              [disabled] { background: #eee; color: #999; }
            </style>
          </head>
          <body>
            <h1>Form fixture</h1>

            <!--
              No id, no data-testid, no value. The placeholder and the name are the
              only handles these three have, which is exactly the case the tree used
              to answer with three indistinguishable lines.
            -->
            <div class="row"><input name="given-name" placeholder="First name"></div>
            <div class="row"><input name="family-name" placeholder="Last name"></div>
            <div class="row"><input name="email" type="email" placeholder="Email"></div>

            <!--
              A field whose accessible name comes from a separate element rather
              than from aria-label - the resolution a screen reader does and the
              tree did not.
            -->
            <div class="row">
              <span id="doc-label">Document number</span>
              <input name="document" aria-labelledby="doc-label" placeholder="ABC 123456">
            </div>

            <!--
              Invalid, and it says what is wrong. Without the aria pairing the error
              below is an ordinary sibling div belonging to nothing.
            -->
            <div class="row">
              <input name="postcode" placeholder="Postcode"
                aria-invalid="true" aria-describedby="postcode-error">
              <p id="postcode-error" class="error">Enter a valid postcode</p>
            </div>

            <!--
              Disabled until the postcode above is filled, so a run can assert that a
              disabled input is CAPTURED (rather than absent) and that it flips.
            -->
            <div class="row"><input name="city" placeholder="City" disabled></div>

            <!--
              The input types whose role used to be flattened to `textField`. The
              consent box starts unticked so `checked` has both states in one run.
            -->
            <div class="row">
              <input name="consent" type="checkbox" aria-label="Accept the terms">
              <input name="plan" type="radio" value="a" aria-label="Plan A" checked>
              <input name="plan" type="radio" value="b" aria-label="Plan B">
              <input name="volume" type="range" aria-label="Volume" min="0" max="10" value="5">
              <input name="submit-form" type="submit" value="Confirm">
            </div>

            <!--
              A dropdown built the way component frameworks build them: a div with a
              click handler bound in JS, no <select>, no id, no tabindex, and its
              options inserted only once it opens. Before that first tap there is
              nothing in the tree but the label - which is the whole problem, since
              the agent then has a label and no executable next step.
              Two signals it DOES publish, and they are the fix: `aria-haspopup`
              (declarative, authoritative) and `cursor: pointer` (what the page tells
              a human, and inherited - so only the node where it STARTS counts).
            -->
            <div class="row">
              <span id="edu-label">Education</span>
              <div class="fake-select" role="combobox" aria-haspopup="listbox"
                aria-expanded="false" aria-labelledby="edu-label"
                style="cursor:pointer;border:1px solid #999;padding:10px">
                <span class="fake-select__value">Choose one</span>
              </div>
              <div class="fake-options" hidden></div>
            </div>

            <!--
              The inheritance trap, asserted rather than assumed: `cursor` is an
              inherited property, so a pointer on a wrapper computes as pointer on
              every descendant. Marking all of them tappable would turn one control
              into four. Only the outermost node - where the pointer starts - is one.
            -->
            <div class="row" style="cursor:pointer" id="pointer-root">
              <div><span id="pointer-leaf">Nested under a pointer wrapper</span></div>
            </div>

            <!--
              A tri-state "select all", the case a plain boolean cannot carry.
            -->
            <div class="row">
              <span role="checkbox" aria-checked="mixed" tabindex="0"
                aria-label="Select all consents">Select all</span>
            </div>

            <script>
              // The options exist only after the trigger is tapped - the shape that
              // makes an unopened dropdown unreachable rather than merely empty.
              var fakeSelect = document.querySelector('.fake-select');
              var fakeOptions = document.querySelector('.fake-options');
              fakeSelect.addEventListener('click', function() {
                var open = fakeSelect.getAttribute('aria-expanded') === 'true';
                fakeSelect.setAttribute('aria-expanded', open ? 'false' : 'true');
                if (open) { fakeOptions.hidden = true; return; }
                if (!fakeOptions.childNodes.length) {
                  ['Primary', 'Secondary', 'University'].forEach(function(name) {
                    var row = document.createElement('div');
                    row.setAttribute('role', 'option');
                    row.style.cursor = 'pointer';
                    row.style.padding = '10px';
                    row.appendChild(document.createTextNode(name));
                    row.addEventListener('click', function() {
                      fakeSelect.querySelector('.fake-select__value').textContent = name;
                      fakeSelect.setAttribute('aria-expanded', 'false');
                      fakeOptions.hidden = true;
                    });
                    fakeOptions.appendChild(row);
                  });
                }
                fakeOptions.hidden = false;
              });

              // The city field unlocks once the postcode has content - the
              // enable-on-dependency shape, so `isEnabled` is observed flipping
              // rather than only ever read as a constant.
              var postcode = document.querySelector('input[name=postcode]');
              var city = document.querySelector('input[name=city]');
              postcode.addEventListener('input', function() {
                city.disabled = postcode.value.length === 0;
                postcode.setAttribute('aria-invalid', postcode.value.length === 0 ? 'true' : 'false');
              });
            </script>
          </body>
        </html>
    """.trimIndent()



    private val scaledHtml: String = """
        <!doctype html>
        <html>
          <head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
          <body style="margin:0;font-family:sans-serif">
            <div style="height:300px"></div>
            <!--
              Far enough down the page that a scale error is unmistakable: the error
              is proportional to the offset, so a target near the origin would pass
              under both the right factor and the wrong one.
              The onclick is the point of the whole fixture - only a COORDINATE tap
              that lands on the real pixels can fire it, so a wrong rect cannot pass.
            -->
            <button id="scaled-target" data-testid="scaled.target"
              style="margin:0 40px;padding:20px 30px;font-size:20px"
              onclick="document.getElementById('scaled-status').innerText='Scaled target hit'">
              Deep target
            </button>
            <p id="scaled-status" data-testid="scaled.status">Not hit</p>
          </body>
        </html>
    """.trimIndent()



    private val nestedBackdropHtml: String = """
        <!doctype html>
        <html>
          <head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
          <body style="margin:0;font-family:sans-serif;background:#eef">
            <h2 id="backdrop-title" data-testid="nested.backdropTitle">Host page</h2>
            <button id="backdrop-button" data-testid="nested.backdropButton"
              style="margin:20px;padding:16px"
              onclick="this.innerText='Backdrop hit'">Backdrop action</button>
          </body>
        </html>
    """.trimIndent()

    private val nestedOverlayHtml: String = """
        <!doctype html>
        <html>
          <head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
          <body style="margin:0;font-family:sans-serif;background:#fff">
            <div style="height:220px"></div>
            <!--
              Deep enough into its own page that this element's rect can only be
              right if BOTH the overlay container's screen offset and the page
              offset are added. The onclick makes a coordinate tap the verdict:
              a rect computed against the backdrop's origin is plausible and wrong,
              and lands on the backdrop instead.
            -->
            <button id="overlay-button" data-testid="nested.overlayButton"
              style="margin:0 30px;padding:18px 26px;font-size:18px"
              onclick="document.getElementById('overlay-status').innerText='Overlay hit'">
              Overlay action
            </button>
            <p id="overlay-status" data-testid="nested.overlayStatus">Not hit</p>
          </body>
        </html>
    """.trimIndent()


    // Shared modal-overlay styling for the two web dialog fixtures.
    private val modalCss: String = """
        body { font-family: sans-serif; margin: 16px; }
        .overlay {
          position: fixed; inset: 0; display: none;
          align-items: center; justify-content: center;
          background: rgba(0,0,0,0.45);
        }
        .overlay.open { display: flex; }
        .card {
          background: #fff; border-radius: 16px; padding: 24px;
          width: 280px; text-align: center;
          box-shadow: 0 8px 32px rgba(0,0,0,0.25);
        }
        .card h2 { font-size: 18px; margin: 12px 0 8px; }
        .card p { font-size: 14px; color: #444; margin: 0 0 20px; }
        .card button { font-size: 15px; padding: 10px 18px; margin: 0 6px; }
        #lottie-anim { width: 96px; height: 96px; margin: 0 auto; }
    """.trimIndent()

    private fun webLottieHtml(lottieJs: String, animJson: String): String = """
        <!doctype html>
        <html>
          <head>
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <style>$modalCss</style>
          </head>
          <body>
            <p id="web-status" data-testid="webLottie.status">Idle</p>
            <button id="open-lottie" data-testid="webLottie.trigger" onclick="openLottieDialog()">
              Show status dialog
            </button>
            <div id="lottie-dialog" class="overlay" data-testid="webLottie.dialog"
              role="dialog" aria-modal="true" aria-label="Please wait">
              <div class="card">
                <div id="lottie-anim" data-testid="webLottie.animation"></div>
                <h2 id="lottie-title" data-testid="webLottie.title">Please wait</h2>
                <p id="lottie-message" data-testid="webLottie.message">Processing your request...</p>
                <button id="lottie-done" data-testid="webLottie.done" onclick="finishLottieDialog()">Done</button>
              </div>
            </div>
            <script>${lottieJs}</script>
            <script>
              var lottieAnimationData = ${animJson};
              var lottieInstance = null;
              function openLottieDialog() {
                document.getElementById('lottie-dialog').classList.add('open');
                if (!lottieInstance) {
                  lottieInstance = lottie.loadAnimation({
                    container: document.getElementById('lottie-anim'),
                    renderer: 'svg', loop: true, autoplay: true,
                    animationData: lottieAnimationData
                  });
                }
              }
              function finishLottieDialog() {
                document.getElementById('lottie-dialog').classList.remove('open');
                document.getElementById('web-status').innerText = 'Done';
              }
            </script>
          </body>
        </html>
    """.trimIndent()

/**
     * A page whose button raises a NATIVE modal from JavaScript. `alert()` blocks
     * the page's JS thread until the app dismisses it, which is what makes this a
     * boundary case rather than another dialog: while it is up, the DOM bridge's
     * `evaluateJavascript` can never call back.
     */
    private val webJsDialogHtml: String = """
        <!doctype html>
        <html>
          <head>
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <style>body { font-family: sans-serif; margin: 16px; }</style>
          </head>
          <body>
            <h1 id="js-title" data-testid="jsDialog.title">Payment</h1>
            <p id="js-status" data-testid="jsDialog.status">Ready</p>
            <button id="js-alert" data-testid="jsDialog.alertButton"
              onclick="alert('Payment failed'); document.getElementById('js-status').innerText = 'Alert dismissed';">
              Pay (raises a JS alert)
            </button>
            <button id="js-busy" data-testid="jsDialog.busyButton"
              onclick="var end = Date.now() + 4000; while (Date.now() < end) {} document.getElementById('js-status').innerText = 'Busy done';">
              Block the JS thread for 4s
            </button>
          </body>
        </html>
    """.trimIndent()

    private val webComponentHtml: String = """
        <!doctype html>
        <html>
          <head>
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <style>body { font-family: sans-serif; margin: 16px; }</style>
          </head>
          <body>
            <p id="wc-status" data-testid="webComponent.status">Idle</p>
            <button id="open-wc" data-testid="webComponent.trigger"
              onclick="document.querySelector('confirm-dialog').setAttribute('open','')">
              Delete item
            </button>
            <confirm-dialog data-testid="webComponent.dialog"></confirm-dialog>
            <script>
              class ConfirmDialog extends HTMLElement {
                constructor() { super(); this.attachShadow({ mode: 'open' }); }
                connectedCallback() {
                  this.shadowRoot.innerHTML =
                    '<style>' +
                    ':host{display:none;position:fixed;inset:0;align-items:center;justify-content:center;background:rgba(0,0,0,0.45)}' +
                    ':host([open]){display:flex}' +
                    '.card{background:#fff;border-radius:16px;padding:24px;width:280px;text-align:center;box-shadow:0 8px 32px rgba(0,0,0,0.25)}' +
                    'h2{font-size:18px;margin:0 0 8px}p{font-size:14px;color:#444;margin:0 0 20px}button{font-size:15px;padding:10px 18px;margin:0 6px}' +
                    '</style>' +
                    '<div class="card" role="dialog" aria-modal="true">' +
                    '<h2 id="wc-title" data-testid="webComponent.title">Delete item?</h2>' +
                    '<p id="wc-message" data-testid="webComponent.message">This will remove it permanently.</p>' +
                    '<button id="wc-cancel" data-testid="webComponent.cancel">Cancel</button>' +
                    '<button id="wc-confirm" data-testid="webComponent.confirm">Delete</button>' +
                    '</div>';
                  var self = this;
                  this.shadowRoot.getElementById('wc-confirm').addEventListener('click', function() {
                    self.removeAttribute('open');
                    document.getElementById('wc-status').innerText = 'Deleted';
                  });
                  this.shadowRoot.getElementById('wc-cancel').addEventListener('click', function() {
                    self.removeAttribute('open');
                    document.getElementById('wc-status').innerText = 'Cancelled';
                  });
                }
              }
              customElements.define('confirm-dialog', ConfirmDialog);
            </script>
          </body>
        </html>
    """.trimIndent()
}
