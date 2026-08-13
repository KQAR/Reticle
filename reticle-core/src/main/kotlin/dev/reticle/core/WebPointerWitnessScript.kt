package dev.reticle.core

/**
 * The one script Reticle runs in a page that is not a read: it installs a listener
 * that records where the page's last pointer event actually landed.
 *
 * ## Why a write is the only way to answer this
 *
 * A DOM rect is computed in the page and folded into device coordinates using the
 * host view's frame and any enclosing frame's offset and scale. When that fold is
 * wrong, `act tap` aims at the reported centre, the touch lands somewhere else, and
 * the result still says `settled=1` — measured on a real hybrid page whose rects were
 * off by roughly 130px, where a `--css` tap missed twice and only a screenshot
 * revealed it (#234).
 *
 * Nothing inside the tree can catch that. `document.elementFromPoint` cannot: the
 * point would have to be un-folded back into page coordinates by the same arithmetic
 * that was wrong, so the two errors cancel and it always agrees with itself. Comparing
 * the rect against its host web view catches only the extreme case (a centre folded
 * clean outside the view that draws it — `DomRectCheck`). The only INDEPENDENT source
 * for where a touch went is the page's own account of receiving it, and that needs a
 * listener.
 *
 * ## What it costs the page
 *
 * A capture-phase listener per document for `pointerdown` / `touchstart` /
 * `mousedown`, passive where the browser understands the option, which records a
 * target and a coordinate and does nothing else — it never calls `preventDefault` or
 * `stopPropagation`, and it changes no page state. Installed idempotently on every
 * capture, so it is there before the next gesture; the record is read back by the
 * traversal ([WebViewDomScript]), which compares the recorded target against each
 * element it captures by IDENTITY. That comparison is why the two scripts are read in
 * one place: a second selector implementation would be a third answer to "which node
 * is this".
 *
 * The JavaScript lives ONCE, in `reticle-protocol/scripts/dom-pointer-witness.js`, and
 * is embedded here and in `ReticleProtocol.WebPointerWitnessScript` verbatim;
 * `WebPointerWitnessScriptTest` (Kotlin) and `WebPointerWitnessScriptTests` (Swift)
 * assert each copy equals that file. Same rule, and the same reason, as the traversal.
 */
object WebPointerWitnessScript {
    val SCRIPT: String = """
        (function() {
          // The one script in this directory that WRITES to the page, and it writes the
          // least it can: a capture-phase listener per document and a single record of the
          // last pointer that arrived. Nothing is prevented, nothing is stopped, no page
          // state is changed — see the header of the embedding for why the traversal cannot
          // answer this question on its own.
          var state = window.__reticlePointer;
          if (!state) {
            state = { target: null, x: 0, y: 0, ts: 0 };
            window.__reticlePointer = state;
          }
          var record = function(event) {
            try {
              state.target = event.target || null;
              // A touch event carries its coordinates on the touch, not on itself.
              var at = (event.touches && event.touches.length) ? event.touches[0] : event;
              state.x = Math.round(at.clientX || 0);
              state.y = Math.round(at.clientY || 0);
              state.ts = Date.now();
            } catch (err) {}
          };
          var install = function(doc) {
            try {
              if (!doc || doc.__reticlePointerListening) return 0;
              doc.__reticlePointerListening = true;
              // All three families, because which of them a synthesized touch produces is
              // the platform's business: a WebView tap may arrive as touch + pointer +
              // mouse, or as any subset. They overwrite one another with the same reading.
              var names = ["pointerdown", "touchstart", "mousedown"];
              // Passive where the browser understands the option, so a listener that only
              // observes cannot make the page's own scrolling worse. The boolean form is
              // the fallback for a WebView that reads the third argument as `capture`.
              var options = true;
              try {
                var probe = Object.defineProperty({}, "passive", { get: function() { options = { capture: true, passive: true }; } });
                window.addEventListener("reticleprobe", null, probe);
                window.removeEventListener("reticleprobe", null, probe);
              } catch (err) {}
              for (var i = 0; i < names.length; i++) doc.addEventListener(names[i], record, options);
              return 1;
            } catch (err) {
              return 0;
            }
          };
          var installed = install(document);
          // A same-origin child frame is its own document and events do NOT cross the
          // boundary, so a tap inside one would leave no record at all — which reads as
          // "the touch never reached the page", the opposite of the truth. One level deep
          // and bounded: a sealed frame throws here and stays unwitnessed, which is stated
          // rather than guessed at (see `DomTapWitness`).
          try {
            var frames = window.frames;
            for (var f = 0; f < frames.length && f < 8; f++) {
              try { installed += install(frames[f].document); } catch (err) {}
            }
          } catch (err) {}
          return installed > 0 ? "installed" : "already";
        })();
    """.trimIndent()
}
