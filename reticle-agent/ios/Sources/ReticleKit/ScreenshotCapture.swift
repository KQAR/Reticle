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
        let format = UIGraphicsImageRendererFormat()
        format.scale = primaryScreen.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let image = renderer.image { _ in
            for window in windows {
                // Draw each window at its own screen origin so a presented sheet
                // or alert renders over the base window.
                window.drawHierarchy(in: window.frame, afterScreenUpdates: false)
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
