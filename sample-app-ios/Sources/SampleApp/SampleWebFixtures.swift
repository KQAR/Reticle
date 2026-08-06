import UIKit
import WebKit

/// WKWebView fixtures used to exercise Reticle's read-only DOM bridge — the
/// same HTML as the Android sample's `SampleWebFixtures`, so the folded
/// `domNode` output is comparable across platforms.
enum SampleWebFixtures {

    static func makeComplexWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString(complexHtml, baseURL: URL(string: "https://reticle.dev/sample/complex"))
        return webView
    }

    /// A modal built with `lottie-web` playing a real Lottie animation.
    static func makeLottieDialogWebView() -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let js = bundledResource("lottie_light.min", "js")
        let anim = bundledResource("lottie_anim", "json")
        webView.loadHTMLString(webLottieHtml(lottieJs: js, animJson: anim),
                               baseURL: URL(string: "https://reticle.dev/sample/web-lottie"))
        return webView
    }

    /// A modal built as a Web Component (custom element + open shadow root).
    static func makeWebComponentDialogWebView() -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.loadHTMLString(webComponentHtml,
                               baseURL: URL(string: "https://reticle.dev/sample/web-component"))
        return webView
    }

    /// The page whose button blocks its own JS thread with a bounded busy loop —
    /// the deterministic twin of Android's `alert()` case. While that loop runs,
    /// `evaluateJavaScript` cannot call back, so the DOM read must time out and the
    /// view must degrade to one opaque node reporting `dom:unavailable`.
    ///
    /// (Disabling content JavaScript does NOT reproduce this: measured, the app's
    /// own `evaluateJavaScript` still runs and the DOM reads fine.)
    static func makeDomBlockedWebView() -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.loadHTMLString(webJsDialogHtml,
                               baseURL: URL(string: "https://reticle.dev/sample/web-dom-blocked"))
        return webView
    }

    private static func bundledResource(_ name: String, _ ext: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return text
    }

    static let basicCheckoutHtml = """
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
        """

    static let complexHtml = """
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
              <!--
                Sandboxed, and NOT cross-origin: `sandbox` without
                `allow-same-origin` gives the frame an opaque origin, so
                `contentDocument` is refused exactly as it is for another host —
                on a frame that is plainly same-site. Its own marker
                (`iframe:sandboxed`) is what stops a reader hunting a domain
                problem that does not exist.
              -->
              <iframe id="sandbox-frame" data-testid="complex.sandboxFrame" sandbox="allow-scripts"
                srcdoc="<button id='sandbox-button'
                  onclick='this.innerText=&quot;Sandbox clicked&quot;'>Inside sandboxed frame</button>">
              </iframe>
              <!--
                Re-navigates the sealed frames. This is the app's own button on purpose:
                a per-frame probe only reaches documents loaded AFTER it is installed,
                and Reticle will not reload a page to widen its own reach — that would
                be the observer changing the thing observed. So the boundary is
                exercised the way a real app clears it: the page navigates the frame,
                and the frame is readable from then on.
              -->
              <button id="reload-frames" data-testid="complex.reloadFrames"
                onclick="var f = document.getElementById('sandbox-frame'); f.srcdoc = f.srcdoc;">
                Reload sealed frames
              </button>
              <!--
                A frame under `transform: scale(0.5)` — the shape a responsive
                third-party widget ships in. The content's own pixels are not the
                page's, so a fold that ignores the transform reports the inner
                button at double size in the wrong place, silently and plausibly.
                The button flips its own text, so a COORDINATE tap at the reported
                centre either proves the fold or misses.
              -->
              <iframe id="scaled-frame" data-testid="complex.scaledFrame"
                style="transform: scale(0.5); transform-origin: top left; width: 320px; height: 120px"
                srcdoc="<button id='scaled-frame-button' style='font-size: 28px'
                  onclick='this.innerText=&quot;Scaled frame clicked&quot;'>Inside scaled frame</button>">
              </iframe>
              <!--
                A frame that scrolls its OWN document: the host page's scroll offset
                says nothing about it, so before the frame published its travel there
                was no container for a caller to drive and no way to tell a short
                frame from a truncated one.
              -->
              <iframe id="scroll-frame" data-testid="complex.scrollFrame"
                style="width: 320px; height: 80px"
                srcdoc="<p style='height: 400px'>Frame top</p><button id='scroll-frame-button'>Frame bottom</button>">
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
        """

    // Shared modal-overlay styling for the two web dialog fixtures.
    private static let modalCss = """
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
        """

    private static func webLottieHtml(lottieJs: String, animJson: String) -> String {
        """
        <!doctype html>
        <html>
          <head>
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <style>\(modalCss)</style>
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
            <script>\(lottieJs)</script>
            <script>
              var lottieAnimationData = \(animJson);
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
        """
    }

    /// Kept byte-comparable with the Android fixture's `webJsDialogHtml`.
    static let webJsDialogHtml = """
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
        """

    static let webComponentHtml = """
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
        """
}
