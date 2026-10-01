import Foundation

/// Thin wrapper over `URLSession` for upstream requests.
public struct HTTPClient: Sendable {
    public static let shared = HTTPClient()

    private let session: URLSession

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.httpAdditionalHeaders = ["User-Agent": "TVThing/1.0 (Macintosh)"]
        session = URLSession(configuration: configuration)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// For streams that never end: the caller reads only as much as it needs.
    public func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (bytes, http)
    }

    public func data(from url: URL, timeout: TimeInterval = 15) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        return try await data(for: request)
    }
}

extension Data {
    var isHLSPlaylist: Bool {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let body = starts(with: bom) ? dropFirst(3) : self[...]
        return body.starts(with: Data("#EXTM3U".utf8))
    }
}
