import XCTest
@testable import ReticleKit

/// The agent's HTTP framing. It is a hand-rolled parser reading from an
/// accumulating socket buffer, so the cases that matter are the partial ones:
/// answering a half-arrived request as if it were complete would hand the host a
/// truncated body and blame the app for the difference.
final class HttpMessageTests: XCTestCase {

    private func parse(_ raw: String, maxBody: Int = 1 << 20) -> HttpRequest.ParseResult? {
        HttpRequest.tryParse(Data(raw.utf8), maxBody: maxBody)
    }

    func testAGetRequestParsesMethodAndPath() throws {
        guard case .ok(let request)? = parse("GET /snapshot HTTP/1.1\r\nHost: x\r\n\r\n") else {
            return XCTFail("expected a parsed request")
        }
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/snapshot")
        XCTAssertTrue(request.body.isEmpty)
    }

    func testTheQueryStringIsStrippedBecauseRoutingIsOnThePath() throws {
        // The host appends query params on some calls; a router keyed on the raw
        // target would 404 on exactly those.
        guard case .ok(let request)? = parse("GET /compact?depth=3&x=1 HTTP/1.1\r\n\r\n") else {
            return XCTFail("expected a parsed request")
        }
        XCTAssertEqual(request.path, "/compact")
    }

    func testHeadersThatHaveNotFullyArrivedAskForMore() {
        guard case .needMore? = parse("POST /mutate HTTP/1.1\r\nContent-Len") else {
            return XCTFail("a half-arrived header block must not parse")
        }
    }

    func testABodyShorterThanContentLengthAsksForMore() {
        // The truncation case: without this the agent would decode half a JSON
        // body and report a malformed request the host never sent.
        guard case .needMore? = parse("POST /mutate HTTP/1.1\r\nContent-Length: 10\r\n\r\n{\"a\":1") else {
            return XCTFail("a partial body must not parse")
        }
    }

    func testTheBodyIsCutAtContentLengthAndTheRestIsLeftAlone() throws {
        // A pipelined second request must not bleed into this one's body.
        guard case .ok(let request)? = parse(
            "POST /mutate HTTP/1.1\r\nContent-Length: 7\r\n\r\n{\"a\":1}GET /runtime HTTP/1.1\r\n\r\n"
        ) else {
            return XCTFail("expected a parsed request")
        }
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "{\"a\":1}")
    }

    func testContentLengthIsMatchedCaseInsensitively() throws {
        guard case .ok(let request)? = parse("POST /clipboard HTTP/1.1\r\nCONTENT-LENGTH: 2\r\n\r\nhi") else {
            return XCTFail("expected a parsed request")
        }
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "hi")
    }

    func testABodyOverTheCapIsRefusedRatherThanBuffered() {
        guard case .tooLarge? = parse("POST /mutate HTTP/1.1\r\nContent-Length: 99\r\n\r\n", maxBody: 8) else {
            return XCTFail("an oversized body must be refused, not accumulated")
        }
    }

    func testAMalformedRequestLineIsRejectedByName() {
        guard case .badRequest(let why)? = parse("NONSENSE\r\n\r\n") else {
            return XCTFail("expected a bad request")
        }
        XCTAssertTrue(why.contains("malformed"), why)
    }

    func testNonUtf8HeadersAreRejectedRatherThanGuessed() {
        var data = Data([0xFF, 0xFE, 0xFF])
        data.append(Data("\r\n\r\n".utf8))
        guard case .badRequest(let why)? = HttpRequest.tryParse(data, maxBody: 1024) else {
            return XCTFail("expected a bad request")
        }
        XCTAssertTrue(why.contains("UTF8"), why)
    }

    func testAResponseSerializesWithItsOwnByteCount() throws {
        let body = Data("{\"ok\":true}".utf8)
        let text = String(decoding: HttpResponse.json(200, body).serialize(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"), text)
        // Content-Length counts BYTES, and the host reads exactly that many.
        XCTAssertTrue(text.contains("Content-Length: \(body.count)\r\n"), text)
        XCTAssertTrue(text.contains("Content-Type: application/json; charset=utf-8\r\n"), text)
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{\"ok\":true}"), text)
    }

    func testAMultibyteBodyReportsItsByteLengthNotItsCharacterCount() {
        // "héllo" is 5 characters and 6 bytes; reporting 5 leaves a byte on the
        // socket and desynchronizes the next read.
        let response = HttpResponse.text(200, "héllo")
        let text = String(decoding: response.serialize(), as: UTF8.self)
        XCTAssertTrue(text.contains("Content-Length: 6\r\n"), text)
    }

    func testEveryStatusTheAgentEmitsHasItsOwnReasonPhrase() {
        for (code, reason) in [(400, "Bad Request"), (404, "Not Found"), (413, "Payload Too Large"), (500, "Internal Server Error")] {
            let text = String(decoding: HttpResponse.text(code, "x").serialize(), as: UTF8.self)
            XCTAssertTrue(text.hasPrefix("HTTP/1.1 \(code) \(reason)\r\n"), text)
        }
    }
}
