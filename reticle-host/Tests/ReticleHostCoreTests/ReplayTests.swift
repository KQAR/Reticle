import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ReticleHostCore

@Suite("Replay trace discovery and GIF rendering")
struct ReplayTests {
    @Test func discoversStepsInRecordingOrder() throws {
        let root = try temporaryDirectory()
        try writeTrace(in: root, dir: "20-swipe", manifest: swipeManifest(recordedAt: 20))
        try writeTrace(in: root, dir: "10-tap", manifest: tapManifest(recordedAt: 10))
        try writeTrace(in: root, dir: "30-type", manifest: typeManifest(recordedAt: 30))

        let steps = try ReplayTraceDiscovery.steps(at: root)
        #expect(steps.map(\.gesture) == ["tap", "swipe", "type"])
        #expect(steps.map(\.recordedAtMillis) == [10, 20, 30])
    }

    @Test func acceptsASingleTraceDirectory() throws {
        let root = try temporaryDirectory()
        let dir = try writeTrace(in: root, dir: "10-tap", manifest: tapManifest(recordedAt: 10))
        let steps = try ReplayTraceDiscovery.steps(at: dir)
        #expect(steps.count == 1)
        #expect(steps[0].gesture == "tap")
    }

    @Test func missingTracesThrow() throws {
        let root = try temporaryDirectory()
        #expect(throws: HelperError.self) {
            _ = try ReplayTraceDiscovery.steps(at: root)
        }
        #expect(throws: HelperError.self) {
            _ = try ReplayTraceDiscovery.steps(at: root.appendingPathComponent("nope"))
        }
    }

    @Test func parsesGestureGeometryAndArtifacts() throws {
        let root = try temporaryDirectory()
        let dir = try writeTrace(
            in: root, dir: "10-tap", manifest: tapManifest(recordedAt: 10),
            screenshots: ["before.screenshot.png", "after.screenshot.png"]
        )
        let step = try ReplayTraceDiscovery.step(at: dir)
        #expect(step.tapPoint == CGPoint(x: 540, y: 1200))
        #expect(step.selectorDescription == "testId=checkout.payButton")
        #expect(step.changeCount == 2)
        #expect(step.beforeScreenshot?.lastPathComponent == "before.screenshot.png")
        #expect(step.afterScreenshot?.lastPathComponent == "after.screenshot.png")

        let swipeDir = try writeTrace(in: root, dir: "20-swipe", manifest: swipeManifest(recordedAt: 20))
        let swipe = try ReplayTraceDiscovery.step(at: swipeDir)
        #expect(swipe.strokeFrom == CGPoint(x: 540, y: 1600))
        #expect(swipe.strokeTo == CGPoint(x: 540, y: 600))
        // No screenshot files were written, so artifact names must not resolve.
        #expect(swipe.beforeScreenshot == nil)
        #expect(!swipe.hasScreenshot)
    }

    @Test func ignoresArtifactNamesThatEscapeTheTraceDirectory() throws {
        let root = try temporaryDirectory()
        var manifest = tapManifest(recordedAt: 10)
        manifest["artifacts"] = [
            "beforeScreenshot": "../outside.png",
            "afterScreenshot": "/etc/hosts",
        ]
        let dir = try writeTrace(in: root, dir: "10-tap", manifest: manifest)
        let step = try ReplayTraceDiscovery.step(at: dir)
        #expect(step.beforeScreenshot == nil)
        #expect(step.afterScreenshot == nil)
    }

    @Test func captionsDescribeTheGesture() throws {
        let root = try temporaryDirectory()
        let tap = try ReplayTraceDiscovery.step(
            at: try writeTrace(in: root, dir: "10-tap", manifest: tapManifest(recordedAt: 10)))
        #expect(tap.caption(index: 1, count: 3) == "1/3 tap testId=checkout.payButton")

        let swipe = try ReplayTraceDiscovery.step(
            at: try writeTrace(in: root, dir: "20-swipe", manifest: swipeManifest(recordedAt: 20)))
        #expect(swipe.caption(index: 2, count: 3) == "2/3 swipe (540,1600) → (540,600)")

        let type = try ReplayTraceDiscovery.step(
            at: try writeTrace(in: root, dir: "30-type", manifest: typeManifest(recordedAt: 30)))
        #expect(type.caption(index: 3, count: 3) == "3/3 type testId=search.input 5 chars")
    }

    @Test func rendersAnAnimatedGifFromScreenshots() throws {
        let root = try temporaryDirectory()
        try writeTrace(
            in: root, dir: "10-tap", manifest: tapManifest(recordedAt: 10),
            screenshots: ["before.screenshot.png", "after.screenshot.png"]
        )
        try writeTrace(
            in: root, dir: "20-swipe", manifest: swipeManifest(recordedAt: 20),
            screenshots: ["before.screenshot.png", "after.screenshot.png"]
        )
        // A step without screenshots is skipped, not fatal.
        try writeTrace(in: root, dir: "30-type", manifest: typeManifest(recordedAt: 30))

        let steps = try ReplayTraceDiscovery.steps(at: root)
        let output = root.appendingPathComponent("replay.gif")
        let result = try ReplayRenderer.renderGIF(steps: steps, to: output)

        #expect(result.stepCount == 2)
        #expect(result.frameCount == 4)
        #expect(result.skippedSteps == ["30-type"])
        #expect(FileManager.default.fileExists(atPath: output.path))

        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 4)
        let type = try #require(CGImageSourceGetType(source))
        #expect(type as String == "com.compuserve.gif")
        let frame = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(frame.width == result.canvasWidth)
        #expect(frame.height == result.canvasHeight)
    }

    @Test func readsTheGestureCoordinateSpaceFromTheSnapshot() throws {
        let root = try temporaryDirectory()
        let dir = try writeTrace(in: root, dir: "10-tap", manifest: tapManifest(recordedAt: 10))
        // Without a snapshot file the width is unknown.
        #expect(try ReplayTraceDiscovery.step(at: dir).coordinateSpaceWidth == nil)
        // An iOS-style snapshot: screen size in points, screenshot in pixels.
        try writeSnapshot(in: dir, name: "before.snapshot.json", width: 402, height: 874)
        #expect(try ReplayTraceDiscovery.step(at: dir).coordinateSpaceWidth == 402)
    }

    @Test func drawsTheTapMarkerInSnapshotSpaceNotPixelSpace() throws {
        let root = try temporaryDirectory()
        // Screenshot is 108×240 "pixels"; the snapshot says the screen is
        // 54×120 (points at 2× density). A tap at (27,60) is dead center.
        var manifest = tapManifest(recordedAt: 10)
        manifest["target"] = ["point": ["x": 27, "y": 60], "source": "semantic:testId"]
        let dir = try writeTrace(
            in: root, dir: "10-tap", manifest: manifest,
            screenshots: ["before.screenshot.png", "after.screenshot.png"]
        )
        try writeSnapshot(in: dir, name: "before.snapshot.json", width: 54, height: 120)

        let steps = try ReplayTraceDiscovery.steps(at: root)
        let output = root.appendingPathComponent("replay.gif")
        let result = try ReplayRenderer.renderGIF(steps: steps, to: output)

        // Default layout: screen rect x=12 y=44 w=360 h=800 → canvas 384×856;
        // the marker dot must sit at the canvas center of the screen area.
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let frame = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let centerTopDown = (x: 192, y: result.canvasHeight - 444)
        let center = rgba(of: frame, x: centerTopDown.x, y: centerTopDown.y)
        #expect(center.r > 200)
        #expect(center.g < 120)
        // Where the old pixel-space mapping would have put it — twice as far
        // from the screen origin — must NOT be marker-colored.
        let wrong = rgba(of: frame, x: 12 + 27 * 2 * (360 / 108), y: 44 + 60 * 2 * (800 / 240))
        #expect(!(wrong.r > 200 && wrong.g < 120))
    }

    @Test func refusesATraceWithNoScreenshotsAtAll() throws {
        let root = try temporaryDirectory()
        try writeTrace(in: root, dir: "10-tap", manifest: tapManifest(recordedAt: 10))
        let steps = try ReplayTraceDiscovery.steps(at: root)
        #expect(throws: HelperError.self) {
            _ = try ReplayRenderer.renderGIF(steps: steps, to: root.appendingPathComponent("replay.gif"))
        }
    }

    // MARK: - fixtures

    private func tapManifest(recordedAt: Int64) -> [String: Any] {
        [
            "traceVersion": 1,
            "actionId": "\(recordedAt)-tap",
            "packageName": "dev.reticle.sample",
            "recordedAtMillis": recordedAt,
            "gesture": "tap",
            "selector": ["testId": "checkout.payButton"],
            "target": ["point": ["x": 540, "y": 1200], "source": "semantic:testId"],
            "result": ["gesture": "tap", "x": "540", "y": "1200"],
            "artifacts": [
                "beforeSnapshot": "before.snapshot.json",
                "afterSnapshot": "after.snapshot.json",
                "beforeScreenshot": "before.screenshot.png",
                "afterScreenshot": "after.screenshot.png",
            ],
            "diff": [["field": "nodeCount", "before": "10", "after": "11"], ["field": "text"]],
        ]
    }

    private func swipeManifest(recordedAt: Int64) -> [String: Any] {
        [
            "actionId": "\(recordedAt)-swipe",
            "packageName": "dev.reticle.sample",
            "recordedAtMillis": recordedAt,
            "gesture": "swipe",
            "result": ["gesture": "swipe", "from": "540,1600", "to": "540,600", "durationMs": "300"],
            "artifacts": [
                "beforeSnapshot": "before.snapshot.json",
                "afterSnapshot": "after.snapshot.json",
                "beforeScreenshot": "before.screenshot.png",
                "afterScreenshot": "after.screenshot.png",
            ],
            "diff": [],
        ]
    }

    private func typeManifest(recordedAt: Int64) -> [String: Any] {
        [
            "actionId": "\(recordedAt)-type",
            "packageName": "dev.reticle.sample",
            "recordedAtMillis": recordedAt,
            "gesture": "type",
            "selector": ["testId": "search.input"],
            "result": ["gesture": "type", "chars": "5", "via": "input text"],
            "artifacts": [
                "beforeSnapshot": "before.snapshot.json",
                "afterSnapshot": "after.snapshot.json",
            ],
            "diff": [],
        ]
    }

    @discardableResult
    private func writeTrace(
        in root: URL, dir: String, manifest: [String: Any], screenshots: [String] = []
    ) throws -> URL {
        let traceDir = root.appendingPathComponent(dir, isDirectory: true)
        try FileManager.default.createDirectory(at: traceDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try data.write(to: traceDir.appendingPathComponent("trace.json"))
        for name in screenshots {
            try writePNG(to: traceDir.appendingPathComponent(name))
        }
        return traceDir
    }

    private func writeSnapshot(in dir: URL, name: String, width: Int, height: Int) throws {
        let snapshot: [String: Any] = [
            "schemaVersion": 1,
            "platform": "ios",
            "capturedAtMillis": 1,
            "rootRef": "r0",
            "screen": ["size": ["width": width, "height": height], "density": 2],
            "nodes": [:],
        ]
        let data = try JSONSerialization.data(withJSONObject: snapshot)
        try data.write(to: dir.appendingPathComponent(name))
    }

    /// Samples one pixel (top-down coordinates) from a decoded GIF frame.
    private func rgba(of image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(
            data: &pixel, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    /// Writes a small solid-color PNG standing in for a device screenshot.
    private func writePNG(to url: URL, width: Int = 108, height: Int = 240) throws {
        let ctx = try #require(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(ctx.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
