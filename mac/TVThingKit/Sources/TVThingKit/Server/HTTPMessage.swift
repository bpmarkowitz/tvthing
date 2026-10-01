import Foundation

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data

    /// Path segments without empty components: `/stream/abc/index.m3u8` → `["stream", "abc", "index.m3u8"]`.
    public var pathComponents: [String] {
        path.split(separator: "/").map(String.init)
    }

    func decodeBody<T: Decodable>(_ type: T.Type) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: body)
        } catch {
            throw HTTPError(status: 400, message: "Invalid request body")
        }
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"], body: data)
    }

    static func error(_ message: String, status: Int) -> HTTPResponse {
        json(["error": message], status: status)
    }

    static func playlist(_ text: String) -> HTTPResponse {
        HTTPResponse(headers: ["Content-Type": "application/vnd.apple.mpegurl", "Cache-Control": "no-store"], body: Data(text.utf8))
    }

    static let notFound = error("Not found", status: 404)

    var reasonPhrase: String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }
}

/// Thrown from request handlers to produce an error response.
public struct HTTPError: Error, LocalizedError {
    public var status: Int
    public var message: String

    public init(status: Int, message: String) {
        self.status = status
        self.message = message
    }

    public var errorDescription: String? { message }
}
