import Foundation

/// Any publicly reachable HLS playlist URL.
public struct HLSProvider: StreamProvider {
    public let id = ProviderID.hls
    public let displayName = "HLS stream"
    private let http: HTTPClient

    public init(http: HTTPClient = .shared) {
        self.http = http
    }

    public func accepts(_ input: String) -> Bool {
        guard let url = URL(string: input), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme) && url.host != nil
    }

    public func candidate(for input: String) async throws -> SourceCandidate {
        guard accepts(input), let url = URL(string: input) else { throw ProviderError.unrecognizedInput }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.apple.mpegurl, application/x-mpegURL, */*", forHTTPHeaderField: "Accept")
        // Stream the response: a broadcast URL never ends, so give up as soon as the first
        // bytes show it isn't a playlist (the next provider then gets a turn).
        let (bytes, response) = try await http.bytes(for: request)
        guard (200...299).contains(response.statusCode) else { throw ProviderError.notAPlaylist }
        var head = Data()
        for try await byte in bytes {
            head.append(byte)
            if head.count == 16 { break }
        }
        guard head.isHLSPlaylist else { throw ProviderError.notAPlaylist }
        return SourceCandidate(reference: .init(provider: id, value: url.absoluteString), suggestedName: Self.suggestedName(for: url))
    }

    public func resolve(_ reference: SourceReference, refresh: Bool) async throws -> ResolvedStream {
        guard let url = URL(string: reference.value) else { throw ProviderError.unrecognizedInput }
        return ResolvedStream(playlistURL: url)
    }

    public func summary(of reference: SourceReference) -> String {
        URL(string: reference.value)?.host ?? reference.value
    }

    /// `https://example.com/hls/news/master.m3u8` → `News`.
    static func suggestedName(for url: URL) -> String? {
        let generic: Set<String> = ["master", "index", "playlist", "live", "stream", "hls", "chunklist", "mono"]
        let parts = url.pathComponents
            .map { ($0 as NSString).deletingPathExtension }
            .filter { $0 != "/" && !$0.isEmpty && !generic.contains($0.lowercased()) }
        guard let last = parts.last else { return url.host }
        return last.replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression).capitalized
    }
}
