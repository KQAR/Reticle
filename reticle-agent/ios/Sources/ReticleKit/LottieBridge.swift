import UIKit
import ReticleProtocol

/// Looks inside a Lottie animation — the iOS counterpart of the Android
/// `LottieBridge`.
///
/// A Lottie renders its whole UI into one layer, so the view tree sees a single
/// `LottieAnimationView`. When an app bakes a dialog's title / message / buttons
/// into the animation, none of it is a real view, so nothing downstream can act
/// on it. This recovers those elements from the *parsed model* Lottie holds in
/// memory: it enumerates the text layers, reads their strings, and maps each
/// layer's transform through the composition→view scale to a screen rect —
/// surfaced as `.lottie` sub-regions for the existing region pipeline.
///
/// Pure `Mirror` reflection: the agent must not link Lottie. iOS has no public
/// introspection API and Swift can't invoke a non-`@objc` method by name, so
/// this reads stored properties only. Every step is optional-guarded — a renamed
/// property or an unexpected shape yields no regions rather than a crash. The
/// geometry comes from the same model Lottie draws from; the "this layer is a
/// button" inference is a hint (the label is the layer's own text).
///
/// `@MainActor` because it reads UIView state (`contentMode`) to build the
/// composition→screen map, like every other capture path here. Under Swift 6.1's
/// UIKit annotations that read from a nonisolated context is an error; a newer
/// toolchain accepts it, which is how this compiled locally while CI (Xcode 16.4)
/// rejected it. The whole capture is main-thread work anyway — `SnapshotCapture` is
/// already `@MainActor` and is the only caller.
@MainActor
enum LottieBridge {

    static func regions(for view: UIView, screenFrame: Rect?) -> [InteractionRegion] {
        guard let screenFrame else { return [] }
        guard NSStringFromClass(type(of: view)).contains("LottieAnimationView") else { return [] }
        guard
            let layer = mchild(view, "lottieAnimationLayer"),
            let animation = mchild(layer, "animation"),
            let compW = mchild(animation, "width") as? Double,
            let compH = mchild(animation, "height") as? Double,
            compW > 0, compH > 0,
            let layersAny = mchild(animation, "layers")
        else { return [] }

        let map = ViewMap(view: view, frame: screenFrame, compW: compW, compH: compH)
        return melements(layersAny).compactMap { region(for: $0, map: map) }
    }

    /// A text layer (identified by the presence of a `text` keyframe group) →
    /// one region. Non-text layers carry no readable label and are skipped.
    private static func region(for layer: Any, map: ViewMap) -> InteractionRegion? {
        guard
            let textGroup = mchild(layer, "text"),
            let kfs = mchild(textGroup, "keyframes"),
            let firstKf = melements(kfs).first,
            let doc = mchild(firstKf, "value"),
            let text = mchild(doc, "text") as? String, !text.isEmpty
        else { return nil }

        let fontSize = (mchild(doc, "fontSize") as? Double) ?? 12
        let transform = mchild(layer, "transform")
        let pos = transform.flatMap { firstXY(mchild($0, "position")) } ?? (0, 0)
        let anchor = transform.flatMap { firstXY(mchild($0, "anchorPoint")) } ?? (0, 0)
        let originX = pos.0 - anchor.0
        let originY = pos.1 - anchor.1

        // Prefer the authored text box; fall back to an estimate from the string.
        let framePos = xy(mchild(doc, "textFramePosition"))
        let frameSize = xy(mchild(doc, "textFrameSize"))
        let boxW: Double
        let boxH: Double
        let leftComp: Double
        let topComp: Double
        if let framePos, let frameSize, frameSize.0 > 0, frameSize.1 > 0 {
            boxW = frameSize.0
            boxH = frameSize.1
            leftComp = originX + framePos.0
            topComp = originY + framePos.1
        } else {
            // No authored box: estimate from the string, centered on the layer
            // position (the common center-justified authoring).
            boxW = Double(text.count) * fontSize * 0.6
            boxH = fontSize * 1.2
            leftComp = originX - boxW / 2
            topComp = originY - boxH / 2
        }

        return InteractionRegion(
            source: .lottie,
            label: text,
            rects: [map.rect(leftComp, topComp, boxW, boxH)]
        )
    }

    /// Composition-space → screen-space for the view's contentMode.
    private struct ViewMap {
        let ox: Double, oy: Double, sx: Double, sy: Double
        init(view: UIView, frame: Rect, compW: Double, compH: Double) {
            let vw = frame.width, vh = frame.height
            switch view.contentMode {
            case .scaleToFill:
                sx = vw / compW; sy = vh / compH
                ox = frame.x; oy = frame.y
            case .scaleAspectFill:
                let s = max(vw / compW, vh / compH)
                sx = s; sy = s
                ox = frame.x + (vw - compW * s) / 2
                oy = frame.y + (vh - compH * s) / 2
            default: // .scaleAspectFit — the LottieAnimationView default
                let s = min(vw / compW, vh / compH)
                sx = s; sy = s
                ox = frame.x + (vw - compW * s) / 2
                oy = frame.y + (vh - compH * s) / 2
            }
        }
        func rect(_ l: Double, _ t: Double, _ w: Double, _ h: Double) -> Rect {
            Rect(x: ox + l * sx, y: oy + t * sy, width: w * sx, height: h * sy)
        }
    }

    // MARK: - Mirror helpers (read stored properties only; never throw)

    /// A stored child by label, unwrapping one level of Optional. Walks the
    /// superclass chain — `transform`/`name` live on the `LayerModel` base, and
    /// `Mirror` only lists a class's own stored properties by default. Nil if
    /// absent.
    private static func mchild(_ any: Any, _ label: String) -> Any? {
        var mirror: Mirror? = Mirror(reflecting: any)
        while let m = mirror {
            for c in m.children where c.label == label {
                return unwrap(c.value)
            }
            mirror = m.superclassMirror
        }
        return nil
    }

    private static func unwrap(_ any: Any) -> Any? {
        let m = Mirror(reflecting: any)
        guard m.displayStyle == .optional else { return any }
        guard let inner = m.children.first?.value else { return nil }
        return unwrap(inner)
    }

    private static func melements(_ any: Any) -> [Any] {
        Mirror(reflecting: any).children.map { $0.value }
    }

    /// (x, y) of the first keyframe value in a KeyframeGroup<LottieVector3D>.
    private static func firstXY(_ group: Any?) -> (Double, Double)? {
        guard let group, let kfs = mchild(group, "keyframes"),
              let first = melements(kfs).first, let val = mchild(first, "value") else { return nil }
        return xy(val)
    }

    /// (x, y) of a LottieVector3D.
    private static func xy(_ vec: Any?) -> (Double, Double)? {
        guard let vec, let x = mchild(vec, "x") as? Double, let y = mchild(vec, "y") as? Double else { return nil }
        return (x, y)
    }
}
