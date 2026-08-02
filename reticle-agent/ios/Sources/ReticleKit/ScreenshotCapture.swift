import Foundation
#if canImport(UIKit)
import UIKit

/// In-process screenshot — the iOS analogue of the Android `ScreenshotCapture`.
/// Composites every attached window bottom-to-top at its on-screen offset into
/// one image and encodes PNG. This is the portable path (works on device, where
/// `simctl io screenshot` is unavailable); on the simulator the host may prefer
/// `simctl io` instead.
@MainActor
struct ScreenshotCapture {
    enum ScreenshotError: Error, CustomStringConvertible {
        case noWindows
        case encodeFailed
        var description: String {
            switch self {
            case .noWindows: return "no attached windows to render"
            case .encodeFailed: return "PNG encode failed"
            }
        }
    }

    /// Both arguments are `nil` in production; they are the seams the tests come
    /// in through. A unit-test process has no `UIWindowScene` (so `windows`
    /// mirrors `SnapshotCapture`'s list argument) and no render server at all —
    /// `drawHierarchy` always fails there — so `renderLayer` lets a test supply
    /// window layers directly and exercise the compositing math.
    func capturePng(
        windows explicitWindows: [UIWindow]? = nil,
        renderLayer: ((UIWindow, UIGraphicsImageRenderer) -> UIImage?)? = nil
    ) throws -> Data {
        let windows = explicitWindows ?? orderedWindows()
        guard let primaryScreen = windows.first?.screen ?? UIScreen.optionalMain else {
            throw ScreenshotError.noWindows
        }
        let bounds = primaryScreen.bounds
        let layerFormat = UIGraphicsImageRendererFormat()
        layerFormat.scale = primaryScreen.scale
        layerFormat.opaque = false
        let layerRenderer = UIGraphicsImageRenderer(bounds: bounds, format: layerFormat)

        // Composite into one bitmap we own, folding each window's layer in as
        // soon as it is rendered. Collecting every layer first and compositing
        // at the end held N full-screen bitmaps at once (~8 MB each at 3x on a
        // large phone); this way the peak is the composite plus one layer.
        let scale = primaryScreen.scale
        let pixelWidth = Int((bounds.width * scale).rounded())
        let pixelHeight = Int((bounds.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0,
              let composite = CGContext(
                  data: nil,
                  width: pixelWidth,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else {
            throw ScreenshotError.encodeFailed
        }
        composite.setFillColor(UIColor.black.cgColor)
        composite.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        // CoreGraphics is bottom-left origin and in pixels; flip and scale once
        // so the UIKit draws below can use top-left points.
        composite.translateBy(x: 0, y: CGFloat(pixelHeight))
        composite.scaleBy(x: scale, y: -scale)

        // Render each window into its own transparent layer and composite only
        // the ones that actually drew. `drawHierarchy` black-fills the rect and
        // returns false when a window's content is not renderable in-process —
        // notably the keyboard's UITextEffectsWindow, which attaches to the
        // scene on first text focus and stays attached forever; drawn into a
        // shared context it blacked out every screenshot after the first
        // keyboard appearance. A window that fails to render is skipped
        // honestly rather than allowed to cover the app content below it.
        var composited = false
        for window in windows {
            autoreleasepool {
                let rendered = renderLayer.map { $0(window, layerRenderer) }
                    ?? defaultLayer(for: window, renderer: layerRenderer)
                guard let layer = rendered else { return }
                // Push per layer rather than around the whole loop: the layer
                // renderer pushes a context of its own, and nesting ours inside
                // it would leave the current-context stack to luck.
                UIGraphicsPushContext(composite)
                layer.draw(at: .zero)
                UIGraphicsPopContext()
                composited = true
            }
        }
        guard composited else { throw ScreenshotError.noWindows }

        guard let cgImage = composite.makeImage() else { throw ScreenshotError.encodeFailed }
        let image = UIImage(cgImage: cgImage, scale: scale, orientation: .up)
        guard let data = image.pngData() else { throw ScreenshotError.encodeFailed }
        return data
    }

    /// One window's layer, or nil when it refused to render in-process.
    private func defaultLayer(for window: UIWindow, renderer: UIGraphicsImageRenderer) -> UIImage? {
        var drawn = false
        let layer = renderer.image { _ in
            // Draw each window at its own screen origin so a presented sheet or
            // alert renders over the base window.
            drawn = window.drawHierarchy(in: window.frame, afterScreenUpdates: false)
        }
        return drawn ? layer : nil
    }

    private func orderedWindows() -> [UIWindow] {
        var windows: [UIWindow] = []
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            windows.append(contentsOf: windowScene.windows)
        }
        // Sort by (level, original index): Swift's `sorted` is not guaranteed
        // stable, so sorting by level alone lets two same-level windows (main +
        // overlay, both `.normal` — the common case) swap composite order
        // between runs, flipping which one paints on top. `UIWindowScene.windows`
        // is back-to-front within a level, so the index tiebreak preserves it.
        return windows.enumerated()
            .sorted { ($0.element.windowLevel.rawValue, $0.offset) < ($1.element.windowLevel.rawValue, $1.offset) }
            .map(\.element)
    }
}

private extension UIScreen {
    // UIScreen.main is deprecated on newer SDKs; fall back through it only when a
    // window screen is unavailable.
    static var optionalMain: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }
            .first
    }
}
#endif
