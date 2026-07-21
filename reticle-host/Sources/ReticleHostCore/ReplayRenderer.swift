import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Renders a recorded action-trace flow into an animated GIF: each step
/// contributes its before-screenshot (with the gesture marker drawn where the
/// input landed) and its after-screenshot, framed in a device bezel with a
/// step caption. Pure ImageIO/CoreGraphics — no new dependencies; the host is
/// macOS-only so the system encoders are always present.
enum ReplayRenderer {
    struct Options {
        /// Rendered screenshot width in output pixels (height follows the
        /// first screenshot's aspect ratio).
        var screenWidth: Int = 360
        /// Base frame duration; before-frames hold this, after-frames 1.5×,
        /// and the final frame 3× so the loop end is readable.
        var frameMs: Int = 800
    }

    struct Result {
        let outputURL: URL
        let stepCount: Int
        let frameCount: Int
        let canvasWidth: Int
        let canvasHeight: Int
        /// Action ids of steps that carried no screenshots and were skipped.
        let skippedSteps: [String]
    }

    private struct Frame {
        let image: CGImage
        let caption: String
        let marker: Marker?
        /// Width of the space the marker coordinates live in (snapshot
        /// `screen.size.width`); falls back to the image width when the trace
        /// carried no snapshot.
        let coordinateWidth: CGFloat?
        let delaySeconds: Double
    }

    private enum Marker {
        case tap(CGPoint)
        case stroke(from: CGPoint, to: CGPoint)
    }

    // Layout + palette constants (output pixels).
    private static let pad: CGFloat = 12
    private static let captionBar: CGFloat = 44
    private static let screenCornerRadius: CGFloat = 12
    private static let bezelColor = CGColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1)
    private static let letterboxColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    private static let captionColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    private static let markerColor = CGColor(red: 1.0, green: 0.27, blue: 0.35, alpha: 1)

    static func renderGIF(steps: [ReplayStep], to output: URL, options: Options = Options()) throws -> Result {
        let usable = steps.filter(\.hasScreenshot)
        let skipped = steps.filter { !$0.hasScreenshot }.map(\.actionId)
        guard !usable.isEmpty else {
            throw HelperError("trace has no screenshots to replay (\(steps.count) step(s) found)")
        }

        var frames: [Frame] = []
        for (i, step) in usable.enumerated() {
            let caption = step.caption(index: i + 1, count: usable.count)
            let base = Double(options.frameMs) / 1000.0
            if let url = step.beforeScreenshot, let image = loadImage(url) {
                frames.append(Frame(
                    image: image, caption: caption, marker: marker(for: step),
                    coordinateWidth: step.coordinateSpaceWidth, delaySeconds: base
                ))
            }
            if let url = step.afterScreenshot, let image = loadImage(url) {
                let after = step.changeCount.map { caption + " · Δ\($0)" } ?? caption
                frames.append(Frame(
                    image: image, caption: after, marker: nil,
                    coordinateWidth: step.coordinateSpaceWidth, delaySeconds: base * 1.5
                ))
            }
        }
        guard !frames.isEmpty, let reference = frames.first?.image else {
            throw HelperError("trace screenshots could not be decoded")
        }
        frames[frames.count - 1] = Frame(
            image: frames[frames.count - 1].image,
            caption: frames[frames.count - 1].caption,
            marker: frames[frames.count - 1].marker,
            coordinateWidth: frames[frames.count - 1].coordinateWidth,
            delaySeconds: Double(options.frameMs) * 3 / 1000.0
        )

        // Canvas geometry follows the first screenshot's aspect ratio; later
        // frames with a different size (e.g. rotation) aspect-fit into the
        // same screen rect.
        let screenW = CGFloat(max(80, options.screenWidth))
        let screenH = (screenW * CGFloat(reference.height) / CGFloat(reference.width)).rounded()
        let canvasW = Int(screenW + pad * 2)
        let canvasH = Int(pad + screenH + captionBar)
        let screenRect = CGRect(x: pad, y: captionBar, width: screenW, height: screenH)

        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, "com.compuserve.gif" as CFString, frames.count, nil
        ) else {
            throw HelperError("could not create GIF at \(output.path)")
        }
        let gifProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary
        CGImageDestinationSetProperties(destination, gifProperties)

        for frame in frames {
            let composed = try compose(
                frame: frame, canvasW: canvasW, canvasH: canvasH, screenRect: screenRect
            )
            let frameProperties = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: frame.delaySeconds,
                    kCGImagePropertyGIFUnclampedDelayTime: frame.delaySeconds,
                ]
            ] as CFDictionary
            CGImageDestinationAddImage(destination, composed, frameProperties)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw HelperError("could not write GIF to \(output.path)")
        }

        return Result(
            outputURL: output,
            stepCount: usable.count,
            frameCount: frames.count,
            canvasWidth: canvasW,
            canvasHeight: canvasH,
            skippedSteps: skipped
        )
    }

    private static func marker(for step: ReplayStep) -> Marker? {
        if let from = step.strokeFrom, let to = step.strokeTo { return .stroke(from: from, to: to) }
        if let point = step.tapPoint { return .tap(point) }
        return nil
    }

    private static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func compose(
        frame: Frame, canvasW: Int, canvasH: Int, screenRect: CGRect
    ) throws -> CGImage {
        guard let ctx = CGContext(
            data: nil, width: canvasW, height: canvasH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw HelperError("could not create a \(canvasW)x\(canvasH) render context")
        }

        ctx.setFillColor(bezelColor)
        ctx.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))

        // Screen: rounded clip, letterbox fill, aspect-fit screenshot.
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: screenRect, cornerWidth: screenCornerRadius, cornerHeight: screenCornerRadius, transform: nil))
        ctx.clip()
        ctx.setFillColor(letterboxColor)
        ctx.fill(screenRect)
        let drawn = aspectFit(imageSize: CGSize(width: frame.image.width, height: frame.image.height), in: screenRect)
        ctx.interpolationQuality = .high
        ctx.draw(frame.image, in: drawn)
        if let marker = frame.marker {
            // Marker coordinates live in the snapshot's screen space, which is
            // not necessarily the screenshot's pixel space (iOS: points vs 3×
            // pixels) — scale through the snapshot width when the trace has one.
            let coordinateWidth = frame.coordinateWidth ?? CGFloat(frame.image.width)
            draw(marker: marker, in: ctx, drawnRect: drawn, scale: drawn.width / coordinateWidth)
        }
        ctx.restoreGState()

        drawCaption(frame.caption, in: ctx, canvasW: CGFloat(canvasW))

        guard let image = ctx.makeImage() else {
            throw HelperError("could not render a replay frame")
        }
        return image
    }

    private static func aspectFit(imageSize: CGSize, in rect: CGRect) -> CGRect {
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
            width: size.width, height: size.height
        )
    }

    /// Maps a point in screenshot pixel space (top-left origin) into canvas
    /// coordinates (CG bottom-left origin) within the drawn screenshot rect.
    private static func canvasPoint(_ p: CGPoint, drawnRect: CGRect, scale: CGFloat) -> CGPoint {
        CGPoint(x: drawnRect.minX + p.x * scale, y: drawnRect.maxY - p.y * scale)
    }

    private static func draw(marker: Marker, in ctx: CGContext, drawnRect: CGRect, scale: CGFloat) {
        ctx.setStrokeColor(markerColor)
        ctx.setFillColor(markerColor)
        switch marker {
        case .tap(let p):
            let c = canvasPoint(p, drawnRect: drawnRect, scale: scale)
            ctx.setLineWidth(3)
            ctx.strokeEllipse(in: CGRect(x: c.x - 14, y: c.y - 14, width: 28, height: 28))
            ctx.fillEllipse(in: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10))
        case .stroke(let from, let to):
            let a = canvasPoint(from, drawnRect: drawnRect, scale: scale)
            let b = canvasPoint(to, drawnRect: drawnRect, scale: scale)
            ctx.setLineWidth(4)
            ctx.setLineCap(.round)
            ctx.move(to: a)
            ctx.addLine(to: b)
            ctx.strokePath()
            ctx.fillEllipse(in: CGRect(x: a.x - 6, y: a.y - 6, width: 12, height: 12))
            // Arrowhead at the destination.
            let angle = atan2(b.y - a.y, b.x - a.x)
            for side in [CGFloat.pi * 5 / 6, -CGFloat.pi * 5 / 6] {
                ctx.move(to: b)
                ctx.addLine(to: CGPoint(
                    x: b.x + 14 * cos(angle + side),
                    y: b.y + 14 * sin(angle + side)
                ))
            }
            ctx.strokePath()
        }
    }

    private static func drawCaption(_ text: String, in ctx: CGContext, canvasW: CGFloat) {
        let font = CTFontCreateUIFontForLanguage(.system, 13, nil) ?? CTFontCreateWithName("Helvetica" as CFString, 13, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: captionColor,
        ]
        let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
        var line = CTLineCreateWithAttributedString(attributed)
        let maxWidth = Double(canvasW - pad * 2)
        if CTLineGetTypographicBounds(line, nil, nil, nil) > maxWidth {
            let token = CTLineCreateWithAttributedString(
                CFAttributedStringCreate(nil, "…" as CFString, attributes as CFDictionary)!
            )
            line = CTLineCreateTruncatedLine(line, maxWidth, .end, token) ?? line
        }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let x = (Double(canvasW) - width) / 2
        let y = Double((captionBar - ascent - descent) / 2 + descent)
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
    }
}
