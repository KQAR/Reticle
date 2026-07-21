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

    func capturePng() throws -> Data {
        let windows = orderedWindows()
        guard let primaryScreen = windows.first?.screen ?? UIScreen.optionalMain else {
            throw ScreenshotError.noWindows
        }
        let bounds = primaryScreen.bounds
        let layerFormat = UIGraphicsImageRendererFormat()
        layerFormat.scale = primaryScreen.scale
        layerFormat.opaque = false
        let layerRenderer = UIGraphicsImageRenderer(bounds: bounds, format: layerFormat)

        // Render each window into its own transparent layer and composite only
        // the ones that actually drew. `drawHierarchy` black-fills the rect and
        // returns false when a window's content is not renderable in-process —
        // notably the keyboard's UITextEffectsWindow, which attaches to the
        // scene on first text focus and stays attached forever; drawn into a
        // shared context it blacked out every screenshot after the first
        // keyboard appearance. A window that fails to render is skipped
        // honestly rather than allowed to cover the app content below it.
        var layers: [UIImage] = []
        for window in windows {
            var drawn = false
            let layer = layerRenderer.image { _ in
                // Draw each window at its own screen origin so a presented sheet
                // or alert renders over the base window.
                drawn = window.drawHierarchy(in: window.frame, afterScreenUpdates: false)
            }
            if drawn { layers.append(layer) }
        }
        guard !layers.isEmpty else { throw ScreenshotError.noWindows }

        let format = UIGraphicsImageRendererFormat()
        format.scale = primaryScreen.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let image = renderer.image { context in
            UIColor.black.setFill()
            context.fill(bounds)
            for layer in layers {
                layer.draw(at: .zero)
            }
        }
        guard let data = image.pngData() else { throw ScreenshotError.encodeFailed }
        return data
    }

    private func orderedWindows() -> [UIWindow] {
        var windows: [UIWindow] = []
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            windows.append(contentsOf: windowScene.windows)
        }
        return windows.sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }
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
