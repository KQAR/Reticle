import XCTest
import ReticleProtocol
@testable import ReticleKit

/// Text layers recovered from a Lottie composition.
///
/// The bridge reads the parsed model through `Mirror` and links no Lottie
/// dependency, so a stand-in object graph with the same stored-property names
/// exercises the real code path — including the composition→screen mapping,
/// which is the part that silently produces plausible-but-wrong rects when the
/// content mode is mishandled. `scenario.lottieOnlyDialog` proves the reflection
/// matches a real Lottie build; these pin the arithmetic and the refusals.
@MainActor
final class LottieBridgeTests: XCTestCase {

    // MARK: - A stand-in for Lottie's parsed model

    private struct Vector { let x: Double; let y: Double }
    private struct Keyframe<T> { let value: T }
    private struct KeyframeGroup<T> { let keyframes: [Keyframe<T>] }
    private struct TextDocument {
        let text: String
        let fontSize: Double
        let textFramePosition: Vector?
        let textFrameSize: Vector?
    }
    private struct Transform {
        let position: KeyframeGroup<Vector>
        let anchorPoint: KeyframeGroup<Vector>
    }
    private struct TextLayer {
        let text: KeyframeGroup<TextDocument>
        let transform: Transform
    }
    private struct ShapeLayer { let transform: Transform }
    private struct Animation { let width: Double; let height: Double; let layers: [Any] }
    private struct AnimationLayer { let animation: Animation }

    /// The class-name check is `contains("LottieAnimationView")`, which a Swift
    /// subclass satisfies through its mangled name.
    private final class FakeLottieAnimationView: UIView {
        var lottieAnimationLayer: AnimationLayer?
    }

    private func transform(position: Vector, anchor: Vector = Vector(x: 0, y: 0)) -> Transform {
        Transform(
            position: KeyframeGroup(keyframes: [Keyframe(value: position)]),
            anchorPoint: KeyframeGroup(keyframes: [Keyframe(value: anchor)])
        )
    }

    private func textLayer(
        _ text: String,
        at position: Vector,
        framePosition: Vector? = Vector(x: 0, y: 0),
        frameSize: Vector? = Vector(x: 100, y: 20)
    ) -> TextLayer {
        TextLayer(
            text: KeyframeGroup(keyframes: [Keyframe(value: TextDocument(
                text: text,
                fontSize: 14,
                textFramePosition: framePosition,
                textFrameSize: frameSize
            ))]),
            transform: transform(position: position)
        )
    }

    private func view(
        comp: (Double, Double) = (100, 100),
        layers: [Any],
        frame: CGRect = CGRect(x: 10, y: 20, width: 200, height: 100),
        contentMode: UIView.ContentMode = .scaleToFill
    ) -> FakeLottieAnimationView {
        let view = FakeLottieAnimationView(frame: frame)
        view.contentMode = contentMode
        view.lottieAnimationLayer = AnimationLayer(
            animation: Animation(width: comp.0, height: comp.1, layers: layers)
        )
        return view
    }

    private let screenFrame = Rect(x: 10, y: 20, width: 200, height: 100)

    // MARK: - Tests

    func testATextLayerBecomesALottieRegionCarryingItsString() throws {
        let v = view(layers: [textLayer("Confirm", at: Vector(x: 50, y: 50))])
        let region = try XCTUnwrap(LottieBridge.regions(for: v, screenFrame: screenFrame).first)

        XCTAssertEqual(region.source, .lottie)
        XCTAssertEqual(region.label, "Confirm")
        // scaleToFill over a 100x100 composition in a 200x100 box: sx=2, sy=1.
        // Layer at (50,50) with a (0,0)+(100x20) text box -> (10+100, 20+50, 200, 20).
        let rect = try XCTUnwrap(region.rects.first)
        XCTAssertEqual(rect.x, 110, accuracy: 0.001)
        XCTAssertEqual(rect.y, 70, accuracy: 0.001)
        XCTAssertEqual(rect.width, 200, accuracy: 0.001)
        XCTAssertEqual(rect.height, 20, accuracy: 0.001)
    }

    func testAspectFitCentersTheCompositionInsteadOfStretchingIt() throws {
        // The default a LottieAnimationView actually ships with. Using the
        // scaleToFill maths here would place every rect too far right.
        let v = view(layers: [textLayer("Confirm", at: Vector(x: 50, y: 50))], contentMode: .scaleAspectFit)
        let rect = try XCTUnwrap(LottieBridge.regions(for: v, screenFrame: screenFrame).first?.rects.first)

        // s = min(200/100, 100/100) = 1, so the 100-wide composition is centered:
        // ox = 10 + (200-100)/2 = 60, oy = 20.
        XCTAssertEqual(rect.x, 110, accuracy: 0.001)
        XCTAssertEqual(rect.y, 70, accuracy: 0.001)
        XCTAssertEqual(rect.width, 100, accuracy: 0.001)
    }

    func testTheAnchorPointIsSubtractedFromThePosition() throws {
        let layer = TextLayer(
            text: KeyframeGroup(keyframes: [Keyframe(value: TextDocument(
                text: "Cancel", fontSize: 14,
                textFramePosition: Vector(x: 0, y: 0), textFrameSize: Vector(x: 40, y: 10)
            ))]),
            transform: transform(position: Vector(x: 50, y: 50), anchor: Vector(x: 20, y: 10))
        )
        let rect = try XCTUnwrap(LottieBridge.regions(for: view(layers: [layer]), screenFrame: screenFrame).first?.rects.first)
        // origin = position - anchor = (30, 40) -> screen (10 + 30*2, 20 + 40*1).
        XCTAssertEqual(rect.x, 70, accuracy: 0.001)
        XCTAssertEqual(rect.y, 60, accuracy: 0.001)
    }

    func testALayerWithNoAuthoredTextBoxIsEstimatedAroundItsPosition() throws {
        // Centre-justified authoring with no frame: the estimate must straddle
        // the layer position rather than starting at it.
        let layer = textLayer("Confirm", at: Vector(x: 50, y: 50), framePosition: nil, frameSize: nil)
        let rect = try XCTUnwrap(LottieBridge.regions(for: view(layers: [layer]), screenFrame: screenFrame).first?.rects.first)
        let centerX = rect.x + rect.width / 2
        XCTAssertEqual(centerX, 10 + 50 * 2, accuracy: 0.001)
        XCTAssertGreaterThan(rect.width, 0)
    }

    func testEveryTextLayerIsRecoveredAndNonTextLayersAreSkipped() {
        let v = view(layers: [
            textLayer("Title", at: Vector(x: 50, y: 20)),
            ShapeLayer(transform: transform(position: Vector(x: 50, y: 60))),
            textLayer("Confirm", at: Vector(x: 50, y: 80)),
        ])
        let labels = LottieBridge.regions(for: v, screenFrame: screenFrame).compactMap { $0.label }
        XCTAssertEqual(labels, ["Title", "Confirm"], "a shape layer carries no readable text and must not become a region")
    }

    func testAnEmptyStringIsNotARegion() {
        let v = view(layers: [textLayer("", at: Vector(x: 50, y: 50))])
        XCTAssertTrue(LottieBridge.regions(for: v, screenFrame: screenFrame).isEmpty)
    }

    func testAnOrdinaryViewIsNeverProbed() {
        let plain = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertTrue(LottieBridge.regions(for: plain, screenFrame: screenFrame).isEmpty)
    }

    func testAnUnreadableModelYieldsNothingRatherThanACrash() {
        // The reflection is against a third-party model the agent does not link:
        // a renamed property, a missing animation or a zero-sized composition
        // must all degrade to no regions.
        let noModel = FakeLottieAnimationView(frame: CGRect(x: 10, y: 20, width: 200, height: 100))
        XCTAssertTrue(LottieBridge.regions(for: noModel, screenFrame: screenFrame).isEmpty)

        let zeroSized = view(comp: (0, 0), layers: [textLayer("Confirm", at: Vector(x: 50, y: 50))])
        XCTAssertTrue(LottieBridge.regions(for: zeroSized, screenFrame: screenFrame).isEmpty)
    }

    func testNoScreenFrameMeansNoGeometryAndSoNoRegions() {
        let v = view(layers: [textLayer("Confirm", at: Vector(x: 50, y: 50))])
        XCTAssertTrue(LottieBridge.regions(for: v, screenFrame: nil).isEmpty)
    }
}
