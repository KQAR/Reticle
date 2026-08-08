import XCTest
@testable import ReticleKit

/// A CANARY, not a unit test of logic: real-device coordinate gestures rest on a
/// private UIKit surface (`UITouch._setLocationInWindow:resetPrevious:`, the
/// application's `UITouchesEvent`, `_addTouch:forDelayedDelivery:`). If a future
/// iOS moves or removes one of those, coordinate input on a device stops working —
/// and the useful moment to learn that is here, with the piece named, rather than
/// from a device run where a tap silently does nothing.
///
/// The class-level pieces are checkable in a headless test process; the
/// application-level one is not (there is no `UIApplication` here — the same
/// reason `KeyboardMonitorTests` skips its responder case). The e2e suites cover
/// that end against a real app.
@MainActor
final class DeviceTouchTests: XCTestCase {

    func testTheClassLevelTouchSurfaceStillExistsOnThisOs() {
        let report = DeviceTouch.probe().report
        for piece in ["touch:setWindow:", "touch:setView:", "touch:setPhase:",
                      "touch:setTapCount:", "touch:setTimestamp:",
                      "touch:_setIsFirstTouchForView:",
                      "touch:_setLocationInWindow:resetPrevious:",
                      "event:_addTouch:forDelayedDelivery:", "event:_setTimestamp:"] {
            XCTAssertTrue(report.contains(piece),
                          "the private touch surface changed on this OS — \(piece) is gone: \(report)")
            XCTAssertFalse(report.contains("MISSING \(piece)"),
                           "the private touch surface changed on this OS: \(report)")
        }
    }

    func testTheProbeReportsAMissingPieceByNameRatherThanJustFailing() {
        // The report IS the diagnostic, so it names what it looked for even where a
        // piece is unreachable. Headless, the application-level piece is unreachable,
        // which makes this the case in hand.
        let probe = DeviceTouch.probe()
        XCTAssertTrue(probe.report.contains("app:_touchesEvent"),
                      "the probe must always name the application-level piece: \(probe.report)")
        if UIApplication.shared.connectedScenes.isEmpty {
            // No application object: the probe must say the surface is NOT usable
            // rather than claim a capability it cannot verify.
            XCTAssertFalse(probe.available)
            XCTAssertTrue(probe.report.contains("MISSING app:_touchesEvent"))
        } else {
            XCTAssertTrue(probe.available, probe.report)
        }
    }

    func testATouchIsRefusedWhenNoWindowOfThisProcessHoldsThePoint() throws {
        // The honest failure for a coordinate that belongs to another process (a
        // system alert, SpringBoard): the agent says so instead of reporting a
        // dispatched touch that reached nothing.
        try XCTSkipIf(UIApplication.shared.connectedScenes.isEmpty,
                      "no application in this test process (see the type doc)")
        do {
            try DeviceTouch.tap(at: CGPoint(x: -50, y: -50))
            XCTFail("a point outside every window of this process must not report success")
        } catch let error as DeviceTouch.TouchError {
            XCTAssertTrue("\(error)".contains("no window"), "\(error)")
        }
    }
}
