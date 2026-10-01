import Foundation

/// Proxies an upstream HLS stream through the local server.
///
/// Every URI in a playlist is rewritten to a short local token, so the Car Thing, the
/// Mac's audio player, and FFmpeg all fetch through here. That matters for ad-stitched
/// services: both players see the exact same playlists and segments, so audio and
/// video stay on the same timeline. Concurrent requests for the same resource share a
/// single upstream fetch, and recent responses are cached briefly.
actor HLSRelay {
    struct Upstream: Sendable {
        var entryURL: URL
        var prepare: @Sendable (inout URLRequest) -> Void
    }

    private struct CacheEntry {
        var response: HTTPResponse
        var expires: Date
    }

    private static let playlistLifetime: TimeInterval = 1
    private static let segmentLifetime: TimeInterval = 60
    private static let cacheByteLimit = 48 * 1024 * 1024
    private static let tokenLimit = 4_000

    /// Root-relative prefix for media URIs, e.g. `/stream/ab12cd/m/`.
    private let mediaPrefix: String
    private let http: HTTPClient
    private var upstream: Upstream
    private let onUnauthorized: @Sendable () async -> Upstream?

    private var urlsByToken: [String: URL] = [:]
    private var tokensByURL: [URL: String] = [:]
    private var tokenOrder: [String] = []
    private var nextToken = 0
    private var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: Task<HTTPResponse, Error>] = [:]

    init(mediaPrefix: String, upstream: Upstream, http: HTTPClient, onUnauthorized: @escaping @Sendable () async -> Upstream?) {
        self.mediaPrefix = mediaPrefix
        self.upstream = upstream
        self.http = http
        self.onUnauthorized = onUnauthorized
    }

    func entry(range: String?) async throws -> HTTPResponse {
        try await fetch(upstream.entryURL, range: range)
    }

    func media(token: String, range: String?) async throws -> HTTPResponse {
        guard let url = urlsByToken[token] else { throw HTTPError(status: 404, message: "Expired media reference") }
        return try await fetch(url, range: range)
    }

    // MARK: - Fetching

    private func fetch(_ url: URL, range: String?) async throws -> HTTPResponse {
        let key = url.absoluteString + "|" + (range ?? "")
        if let entry = cache[key], entry.expires > .now { return entry.response }
        if let task = inFlight[key] { return try await task.value }

        let task = Task { try await self.load(url, range: range, key: key) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    private func load(_ url: URL, range: String?, key: String) async throws -> HTTPResponse {
        let (data, status, headers) = try await download(url, range: range)
        let isPlaylist = data.isHLSPlaylist
        var body = data
        var responseHeaders = ["Cache-Control": "no-store"]
        if isPlaylist, let text = String(data: data, encoding: .utf8) {
            body = Data(rewrite(text, base: url).utf8)
            responseHeaders["Content-Type"] = "application/vnd.apple.mpegurl"
        } else {
            responseHeaders["Content-Type"] = headers["Content-Type"] ?? Self.contentType(for: url)
            if let contentRange = headers["Content-Range"] { responseHeaders["Content-Range"] = contentRange }
        }
        let response = HTTPResponse(status: status, headers: responseHeaders, body: body)
        store(response, for: key, lifetime: isPlaylist ? Self.playlistLifetime : Self.segmentLifetime)
        return response
    }

    private func download(_ url: URL, range: String?) async throws -> (Data, Int, [String: String]) {
        if url.isFileURL {
            do {
                return (try Data(contentsOf: url), 200, [:])
            } catch {
                throw HTTPError(status: 404, message: "Stream data isn't ready yet")
            }
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        upstream.prepare(&request)

        let (data, response) = try await http.data(for: request)
        if response.statusCode == 401 || response.statusCode == 403 {
            // Typically an expired session token. Refresh it so the players' retries succeed.
            if let refreshed = await onUnauthorized() { upstream = refreshed }
            throw HTTPError(status: 502, message: "Upstream session expired; refreshing")
        }
        guard (200...299).contains(response.statusCode) else {
            throw HTTPError(status: 502, message: "Upstream returned HTTP \(response.statusCode)")
        }
        var headers: [String: String] = [:]
        for name in ["Content-Type", "Content-Range"] {
            if let value = response.value(forHTTPHeaderField: name) { headers[name] = value }
        }
        return (data, response.statusCode, headers)
    }

    // MARK: - Playlist rewriting

    func rewrite(_ text: String, base: URL) -> String {
        text.components(separatedBy: "\n").map { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { return rawLine }
            if !line.hasPrefix("#") { return localURI(for: line, base: base) ?? rawLine }
            return rewriteAttributeURIs(in: rawLine, base: base)
        }.joined(separator: "\n")
    }

    private func rewriteAttributeURIs(in line: String, base: URL) -> String {
        guard line.contains("URI=\"") else { return line }
        var output = ""
        var remainder = line[...]
        while let start = remainder.range(of: "URI=\"") {
            output += remainder[..<start.upperBound]
            remainder = remainder[start.upperBound...]
            guard let end = remainder.firstIndex(of: "\"") else { break }
            let value = String(remainder[..<end])
            output += localURI(for: value, base: base) ?? value
            remainder = remainder[end...]
        }
        return output + remainder
    }

    private func localURI(for reference: String, base: URL) -> String? {
        guard let url = URL(string: reference, relativeTo: base)?.absoluteURL,
              ["http", "https", "file"].contains(url.scheme?.lowercased()) else { return nil }
        return mediaPrefix + token(for: url)
    }

    private func token(for url: URL) -> String {
        if let existing = tokensByURL[url] { return existing }
        nextToken += 1
        let token = String(nextToken, radix: 36) + Self.extensionSuffix(for: url)
        urlsByToken[token] = url
        tokensByURL[url] = token
        tokenOrder.append(token)
        // Live playlists roll forward forever; forget the oldest references.
        if tokenOrder.count > Self.tokenLimit {
            let expired = tokenOrder.removeFirst()
            if let url = urlsByToken.removeValue(forKey: expired) { tokensByURL[url] = nil }
        }
        return token
    }

    // MARK: - Cache

    private func store(_ response: HTTPResponse, for key: String, lifetime: TimeInterval) {
        let now = Date.now
        cache = cache.filter { $0.value.expires > now }
        cache[key] = CacheEntry(response: response, expires: now.addingTimeInterval(lifetime))
        var total = cache.values.reduce(0) { $0 + $1.response.body.count }
        for (key, entry) in cache.sorted(by: { $0.value.expires < $1.value.expires }) where total > Self.cacheByteLimit {
            cache[key] = nil
            total -= entry.response.body.count
        }
    }

    // MARK: - Helpers

    /// Keeps a recognizable extension on tokens; some players sniff it.
    private static func extensionSuffix(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ["m3u8", "ts", "aac", "m4s", "mp4", "key", "vtt"].contains(ext) ? ".\(ext)" : ""
    }

    private static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "ts": "video/mp2t"
        case "aac": "audio/aac"
        case "m4s", "mp4": "video/mp4"
        case "vtt": "text/vtt"
        default: "application/octet-stream"
        }
    }
}
