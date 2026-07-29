import XCTest
import ReticleProtocol
@testable import ReticleKit

/// The small surfaces every capture path leans on: colour formatting, the
/// mutation allowlist, and the router's refusal for an unknown route.
@MainActor
final class AgentSurfaceTests: XCTestCase {

    // MARK: - ColorHex

    func testAColorRendersAsAarrggbbInThatOrder() {
        // The wire format is #AARRGGBB (alpha FIRST), matching the Android agent.
        // Emitting #RRGGBBAA here would make every colour comparison across the
        // two platforms wrong in a way that still looks like a colour.
        let traits = UITraitCollection(userInterfaceStyle: .light)
        XCTAssertEqual(ColorHex.hex(.red, in: traits), "#FFFF0000")
        XCTAssertEqual(ColorHex.hex(.blue, in: traits), "#FF0000FF")
        XCTAssertEqual(ColorHex.hex(UIColor.black.withAlphaComponent(0.5), in: traits), "#80000000")
    }

    func testADynamicColorIsResolvedForTheTraitsOnScreen() {
        // A dynamic colour reports nothing useful unresolved; the value must be
        // the one actually being drawn, per interface style.
        let dynamic = UIColor { $0.userInterfaceStyle == .dark ? .white : .black }
        XCTAssertEqual(ColorHex.hex(dynamic, in: UITraitCollection(userInterfaceStyle: .light)), "#FF000000")
        XCTAssertEqual(ColorHex.hex(dynamic, in: UITraitCollection(userInterfaceStyle: .dark)), "#FFFFFFFF")
    }

    func testAWideGamutColorIsClampedIntoTheByteRangeRatherThanOverflowing() {
        let p3 = UIColor(displayP3Red: 1.2, green: -0.3, blue: 0.5, alpha: 1)
        let hex = ColorHex.hex(p3, in: UITraitCollection(userInterfaceStyle: .light))
        XCTAssertEqual(hex.count, 9)
        XCTAssertTrue(hex.hasPrefix("#FF"), hex)
    }

    // MARK: - Mutation allowlist

    func testAPropertyOutsideTheAllowlistIsRefusedByName() {
        // The allowlist is the whole safety story for live patching: an arbitrary
        // KVC write into a running app is exactly what this must not become.
        for property in ["transform", "frame", "delegate", "layer.contents"] {
            let result = MutationEngine().apply(MutationRequest(
                selector: Selector(testId: "whatever"),
                property: property,
                value: .text("x")
            ))
            XCTAssertFalse(result.applied, "'\(property)' must not be writable")
            let message = result.message ?? ""
            XCTAssertTrue(message.contains("allowlist"), message)
            XCTAssertTrue(message.contains(property), "the refusal should name what was refused: \(message)")
        }
    }

    func testAnAllowlistedPropertyGetsPastTheAllowlistAndFailsOnResolutionInstead() {
        // Distinguishes "refused the property" from "could not find the view":
        // collapsing the two would make a typo'd selector read as a blocked
        // property, sending a caller to change the wrong thing.
        let result = MutationEngine().apply(MutationRequest(
            selector: Selector(testId: "no.such.node"),
            property: "alpha",
            value: .real(0.3)
        ))
        XCTAssertFalse(result.applied)
        let message = result.message ?? ""
        XCTAssertFalse(message.contains("allowlist"), message)
        XCTAssertTrue(message.contains("no view matched"), message)
    }

    // MARK: - Router

    func testAnUnknownRouteIs404WithTheMethodAndPathInTheBody() {
        // A 404 that does not say what it refused sends the caller looking at the
        // device instead of at the URL.
        let response = Router().route(HttpRequest(method: "GET", path: "/nope", body: Data()))
        XCTAssertEqual(response.status, 404)
        let body = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(body.contains("GET"), body)
        XCTAssertTrue(body.contains("/nope"), body)
    }

    func testARouteIsMatchedOnMethodAsWellAsPath() {
        // /mutate is POST-only; answering a GET would run a mutation decode over
        // an empty body and report a parse failure instead of a routing one.
        let response = Router().route(HttpRequest(method: "GET", path: Endpoints.mutate, body: Data()))
        XCTAssertEqual(response.status, 404)
    }
}
