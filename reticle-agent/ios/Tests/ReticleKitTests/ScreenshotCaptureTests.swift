import XCTest
@testable import ReticleKit

/// The composite path: windows are folded into one bitmap we own, one layer at
/// a time, instead of being collected and drawn at the end. That saved memory
/// (peak was N full-screen bitmaps, now it is two) but moved the flip and the
/// scaling into hand-written CoreGraphics, so pin what the old code got for
/// free — orientation, stacking order, and scale.
///
/// The window layers are supplied through the `renderLayer` seam: a headless
/// xctest process has no render server, so `drawHierarchy` fails for every
/// window there ("Render server returned error for view"). What is under test
/// is the compositing, not UIKit's rasterizer.
@MainActor
final class ScreenshotCaptureTests: XCTestCase {

    private func makeWindow(_ color: UIColor, height: CGFloat = 844) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: height))
        window.backgroundColor = color
        window.isHidden = false
        return window
    }

    /// Paints the window's own colour over its own frame — a stand-in for what
    /// `drawHierarchy` would have produced.
    private func solidColorLayer(_ window: UIWindow, _ renderer: UIGraphicsImageRenderer) -> UIImage? {
        renderer.image { context in
            (window.backgroundColor ?? .clear).setFill()
            context.fill(window.frame)
        }
    }

    private func pixel(_ image: UIImage, atX x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let cg = image.cgImage, let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let offset = y * cg.bytesPerRow + x * 4
        guard offset + 3 < CFDataGetLength(data) else { return nil }
        // Read back through the PNG, which decodes to plain R,G,B,x order —
        // not the composite context's own little-endian layout.
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }

    func testTheTopWindowPaintsOverTheOneBelowRightWayUp() throws {
        let base = makeWindow(.blue)
        // Only the upper half is covered, so one image proves both that the
        // overlay wins where it draws and that the base survives where it doesn't
        // — and that the flip into CoreGraphics coordinates went the right way.
        let overlay = makeWindow(.red, height: 422)

        let data = try ScreenshotCapture().capturePng(
            windows: [base, overlay], renderLayer: solidColorLayer)
        let image = try XCTUnwrap(UIImage(data: data))
        let cg = try XCTUnwrap(image.cgImage)

        // The canvas is the screen at its native scale, whatever simulator this
        // runs on — a point-sized bitmap would mean the scaling was dropped.
        let screen = base.screen
        let scale = screen.scale
        XCTAssertEqual(cg.width, Int((screen.bounds.width * scale).rounded()))
        XCTAssertEqual(cg.height, Int((screen.bounds.height * scale).rounded()))

        let step = Int(scale)
        let top = try XCTUnwrap(pixel(image, atX: 195 * step, y: 100 * step))
        let bottom = try XCTUnwrap(pixel(image, atX: 195 * step, y: 700 * step))
        XCTAssertGreaterThan(top.r, 200)
        XCTAssertLessThan(top.b, 60)
        XCTAssertGreaterThan(bottom.b, 200)
        XCTAssertLessThan(bottom.r, 60)
    }

    func testAWindowThatRefusesToRenderIsSkippedNotDrawnBlack() throws {
        // The keyboard's UITextEffectsWindow is this case in production: it
        // stays attached forever and never renders in-process. Skipping it has
        // to leave the app content below intact.
        let base = makeWindow(.blue)
        let unrenderable = makeWindow(.red)
        let data = try ScreenshotCapture().capturePng(windows: [base, unrenderable]) { window, renderer in
            window === unrenderable ? nil : self.solidColorLayer(window, renderer)
        }
        let image = try XCTUnwrap(UIImage(data: data))
        let center = try XCTUnwrap(pixel(image, atX: 195 * Int(base.screen.scale), y: 400 * Int(base.screen.scale)))
        XCTAssertGreaterThan(center.b, 200)
    }

    func testNoRenderableWindowIsAnError() {
        XCTAssertThrowsError(try ScreenshotCapture().capturePng(windows: []))
        let window = makeWindow(.blue)
        XCTAssertThrowsError(try ScreenshotCapture().capturePng(windows: [window]) { _, _ in nil })
    }
}
