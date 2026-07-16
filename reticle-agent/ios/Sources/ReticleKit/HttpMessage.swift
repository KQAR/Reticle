import Foundation

/// A parsed HTTP request: method, path, and a decoded body.
struct HttpRequest {
    let method: String
    let path: String
    let body: Data

    enum ParseResult {
        case needMore
        case tooLarge
        case badRequest(String)
        case ok(HttpRequest)
    }

    /// Parse a request from an accumulating buffer. Returns `.needMore` until the
    /// full headers (and any Content-Length body) have arrived, so the caller can
    /// keep receiving. Header parsing is byte-wise ASCII; the body is left raw.
    static func tryParse(_ buffer: Data, maxBody: Int) -> ParseResult? {
        // Find the header/body separator (CRLF CRLF).
        let sep = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let range = buffer.range(of: sep) else {
            return .needMore
        }
        let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .badRequest("non-UTF8 headers")
        }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else {
            return .badRequest("empty request")
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return .badRequest("malformed request line")
        }
        let method = String(parts[0])
        // Strip any query string; the agent routes on the path only.
        let rawPath = String(parts[1])
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath

        var contentLength = 0
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = line.drop(while: { $0 != ":" }).dropFirst().trimmingCharacters(in: .whitespaces)
                contentLength = Int(value) ?? 0
            }
        }
        if contentLength < 0 { return .badRequest("negative content-length") }
        if contentLength > maxBody { return .tooLarge }

        let bodyStart = range.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        if available < contentLength {
            return .needMore
        }
        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        return .ok(HttpRequest(method: method, path: path, body: body))
    }
}

/// An HTTP response with a status, content type, and raw body bytes.
struct HttpResponse {
    let status: Int
    let contentType: String
    let body: Data

    static func json(_ status: Int, _ data: Data) -> HttpResponse {
        HttpResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    static func text(_ status: Int, _ message: String) -> HttpResponse {
        HttpResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(message.utf8))
    }

    static func png(_ data: Data) -> HttpResponse {
        HttpResponse(status: 200, contentType: "image/png", body: data)
    }

    private static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "OK"
        }
    }

    func serialize() -> Data {
        var head = "HTTP/1.1 \(status) \(HttpResponse.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }
}
