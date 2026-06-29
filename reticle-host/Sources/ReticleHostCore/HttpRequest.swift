import Foundation

/// Minimal HTTP request parsed from a localhost daemon connection.
struct HttpRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    /// Parses one HTTP/1.1 request from bytes already read from a connection.
    init(data: Data) throws {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw HelperError("incomplete HTTP request")
        }
        let headerData = data.subdata(in: data.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw HelperError("HTTP headers are not UTF-8")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw HelperError("empty HTTP request")
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else {
            throw HelperError("malformed HTTP request line")
        }

        method = parts[0]
        var components = URLComponents()
        components.percentEncodedPath = parts[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        if let question = parts[1].firstIndex(of: "?") {
            components.percentEncodedQuery = String(parts[1][parts[1].index(after: question)...])
        }
        path = components.path.isEmpty ? "/" : components.path
        query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        var parsedHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            parsedHeaders[key] = value
        }
        headers = parsedHeaders

        let bodyStart = headerEnd.upperBound
        let declaredLength = Int(headers["content-length"] ?? "0") ?? 0
        let availableBody = data.subdata(in: bodyStart..<data.endIndex)
        body = availableBody.prefix(declaredLength)
    }
}

/// Small HTTP response helper for the daemon's REST surface.
struct HttpResponse {
    let status: Int
    let reason: String
    let contentType: String
    let body: Data

    /// Encodes the response as HTTP/1.1 bytes.
    func data() -> Data {
        var data = Data(
            """
            HTTP/1.1 \(status) \(reason)\r
            Content-Type: \(contentType)\r
            Content-Length: \(body.count)\r
            Connection: close\r
            \r

            """.utf8
        )
        data.append(body)
        return data
    }

    /// Creates a JSON response from an encodable value.
    static func json<T: Encodable>(_ value: T, status: Int = 200, reason: String = "OK") throws -> HttpResponse {
        HttpResponse(
            status: status,
            reason: reason,
            contentType: "application/json; charset=utf-8",
            body: try JSONEncoder().encode(value)
        )
    }

    /// Creates a plain-text error response.
    static func text(_ message: String, status: Int, reason: String) -> HttpResponse {
        HttpResponse(
            status: status,
            reason: reason,
            contentType: "text/plain; charset=utf-8",
            body: Data(message.utf8)
        )
    }
}
