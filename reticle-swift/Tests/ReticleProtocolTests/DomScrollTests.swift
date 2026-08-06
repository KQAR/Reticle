import XCTest
@testable import ReticleProtocol

/// Twin: `DomScrollTest` in reticle-core. Same numbers, same verdicts.
final class DomScrollTests: XCTestCase {

    func testAnElementWithNoScrollPortHasNoCapability() {
        XCTAssertNil(
            DomScroll.fromMetrics(
                scrollLeft: -1, scrollTop: -1,
                scrollWidth: -1, scrollHeight: -1,
                clientWidth: -1, clientHeight: -1
            )
        )
    }

    /// The shape that made a bare `scrollHeight > clientHeight` useless: sub-pixel
    /// layout leaves fractions of overflow on panes that cannot scroll at all.
    func testAPortThatCannotMoveIsNotReportedAsScrollable() {
        XCTAssertNil(
            DomScroll.fromMetrics(
                scrollLeft: 0, scrollTop: 0,
                scrollWidth: 300.4, scrollHeight: 300.6,
                clientWidth: 300, clientHeight: 300
            )
        )
    }

    func testTravelIsReportedPerDirectionFromThePortsOwnNumbers() {
        XCTAssertEqual(
            DomScroll.fromMetrics(
                scrollLeft: 0, scrollTop: 0,
                scrollWidth: 300, scrollHeight: 900,
                clientWidth: 300, clientHeight: 300
            ),
            ScrollInfo(canScrollDown: true)
        )
        // Mid-scroll: both ways, on both axes.
        XCTAssertEqual(
            DomScroll.fromMetrics(
                scrollLeft: 100, scrollTop: 300,
                scrollWidth: 900, scrollHeight: 900,
                clientWidth: 300, clientHeight: 300
            ),
            ScrollInfo(
                canScrollUp: true, canScrollDown: true,
                canScrollLeft: true, canScrollRight: true
            )
        )
        // At the end: the only travel left is back.
        XCTAssertEqual(
            DomScroll.fromMetrics(
                scrollLeft: 0, scrollTop: 600,
                scrollWidth: 300, scrollHeight: 900,
                clientWidth: 300, clientHeight: 300
            ),
            ScrollInfo(canScrollUp: true)
        )
    }
}
