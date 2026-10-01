import Foundation

/// Raw MPEG transport streams over HTTP, such as an HDHomeRun tuner's channel URLs
/// (`http://<tuner>:5004/auto/v5.1`). These aren't HLS, so they're always converted by
/// FFmpeg, which reads them directly.
public struct TransportStreamProvider: StreamProvider {
    public let id = ProviderID.transportStream
    public let displayName = "Broadcast stream"
    private let http: HTTPClient

    /// MPEG-TS packets are 188 bytes, each starting with this sync byte.
    static let packetSize = 188
    static let syncByte: UInt8 = 0x47

    public init(http: HTTPClient = .shared) {
        self.http = http
    }

    public func accepts(_ input: String) -> Bool {
        guard let url = URL(string: input), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme) && url.host != nil
    }

    /// Reads just the first few packets: a live tuner stream never ends.
    public func candidate(for input: String) async throws -> SourceCandidate {
        guard accepts(input), let url = URL(string: input) else { throw ProviderError.unrecognizedInput }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (bytes, response) = try await http.bytes(for: request)
        guard (200...299).contains(response.statusCode) else {
            throw ProviderError.unavailable("That stream answered HTTP \(response.statusCode). If it's a tuner, all of its tuners may be in use.")
        }
        var head = Data()
        for try await byte in bytes {
            head.append(byte)
            if head.count >= Self.packetSize * 3 { break }
        }
        // Close the connection now: a tuner stays busy for as long as it's open.
        bytes.task.cancel()
        guard Self.isTransportStream(head) else { throw ProviderError.notAPlaylist }
        return SourceCandidate(reference: .init(provider: id, value: url.absoluteString), suggestedName: nil)
    }

    public func resolve(_ reference: SourceReference, refresh: Bool) async throws -> ResolvedStream {
        guard let url = URL(string: reference.value) else { throw ProviderError.unrecognizedInput }
        return ResolvedStream(playlistURL: url, format: .transportStream)
    }

    public func summary(of reference: SourceReference) -> String {
        guard let url = URL(string: reference.value) else { return reference.value }
        return "Broadcast · \(url.host ?? "")\(url.path)"
    }

    /// Sync bytes at three consecutive packet boundaries.
    static func isTransportStream(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= packetSize * 3 else { return false }
        return (0..<3).allSatisfy { bytes[$0 * packetSize] == syncByte }
    }
}
