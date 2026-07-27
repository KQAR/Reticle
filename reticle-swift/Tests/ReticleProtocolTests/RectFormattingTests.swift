import XCTest
@testable import ReticleProtocol

/// A rect that isn't a rectangle must still be printable.
///
/// UIKit's "no geometry" sentinels (`CGRectInfinite` / `CGRectNull`) reach a
/// capture as ±`CGFloat.greatestFiniteMagnitude` components — a `UIScrollView`'s
/// hidden scroll indicator carries one, so `scenario.wheelPicker` (a
/// `UIPickerView` with four of them) produced four such frames. `Int(someDouble)`
/// **traps** outside `Int`'s range, so formatting one aborted the host process
/// with SIGTRAP while printing an action trace: a bad frame took down the whole
/// report that carried it. The agent now drops such a frame at capture, but a
/// snapshot from an older agent must not be able to kill a renderer either.
final class RectFormattingTests: XCTestCase {

    func testWholeSaturatesInsteadOfTrapping() {
        XCTAssertEqual(Rect.whole(12.7), 12)
        XCTAssertEqual(Rect.whole(-12.7), -12)
        XCTAssertEqual(Rect.whole(.infinity), Int.max)
        XCTAssertEqual(Rect.whole(-.infinity), Int.min)
        XCTAssertEqual(Rect.whole(.nan), 0)
        // The gap that caused the bug: these are FINITE, so an `isFinite` guard
        // waves them through while `Int(_:)` still traps on them.
        XCTAssertTrue(Double.greatestFiniteMagnitude.isFinite)
        XCTAssertEqual(Rect.whole(.greatestFiniteMagnitude), Int.max)
        XCTAssertEqual(Rect.whole(-.greatestFiniteMagnitude), Int.min)
    }

    func testSentinelRectIsRejectedYetStillFormats() {
        // The exact shape a UIPickerView's `_UIScrollViewScrollIndicator` reported.
        let sentinel = Rect(
            x: -.greatestFiniteMagnitude / 2,
            y: -.greatestFiniteMagnitude / 2,
            width: .greatestFiniteMagnitude,
            height: .greatestFiniteMagnitude
        )
        XCTAssertFalse(sentinel.isRepresentable)
        XCTAssertFalse(sentinel.intDescription.isEmpty)
        XCTAssertFalse(sentinel.commaIntDescription.isEmpty)
    }

    func testOrdinaryRectFormatsUnchanged() {
        let r = Rect(x: 24, y: 399.4, width: 354, height: 200)
        XCTAssertTrue(r.isRepresentable)
        XCTAssertEqual(r.intDescription, "24,399 354x200")
        XCTAssertEqual(r.commaIntDescription, "24,399,354x200")
    }

    /// The compact projection is the line an agent actually reads; a sentinel
    /// frame must not stop the rest of the screen from being rendered.
    func testCompactItemWithSentinelFrameRenders() {
        let item = CompactItem(
            ref: "r37",
            role: "view",
            frame: Rect(x: -.greatestFiniteMagnitude / 2, y: 0,
                        width: .greatestFiniteMagnitude, height: 4),
            isEnabled: true,
            isInteractive: false
        )
        XCTAssertFalse(item.line().isEmpty)
    }
}
