import Foundation

/// The one script Reticle runs in a page that is not a read: it installs a listener
/// that records where the page's last pointer event actually landed.
///
/// See `dev.reticle.core.WebPointerWitnessScript` for why a write is the only way to
/// answer the question — the short version is that un-folding a device point back into
/// the page uses the same arithmetic that was wrong, so the page's own account of
/// receiving a touch is the only independent source for where it went.
///
/// The JavaScript lives ONCE, in `reticle-protocol/scripts/dom-pointer-witness.js`, and
/// is embedded here and in the Kotlin twin verbatim; the tests on both sides assert
/// their copy equals that file.
public enum WebPointerWitnessScript {
    public static let script: String = """
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
    """
}
