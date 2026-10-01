import Foundation

/// A source of live HLS streams (a website, a service, or plain URLs).
///
/// Adding a new kind of source means implementing this protocol and registering it in
/// `ProviderRegistry.standard`; the rest of the app only deals in `SourceReference`s.
public protocol StreamProvider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }

    /// A quick, offline check used to route what the user typed to the right provider.
    func accepts(_ input: String) -> Bool

    /// Validates user input and turns it into a reference. May hit the network.
    func candidate(for input: String) async throws -> SourceCandidate

    /// Produces a playable HLS playlist for a reference. Called on every tune, and again
    /// with `refresh` set when upstream rejects a request (for example, an expired token).
    func resolve(_ reference: SourceReference, refresh: Bool) async throws -> ResolvedStream

    /// A short human-readable description of a reference, shown in Settings.
    func summary(of reference: SourceReference) -> String
}

public struct SourceCandidate: Sendable, Equatable {
    public var reference: SourceReference
    public var suggestedName: String?

    public init(reference: SourceReference, suggestedName: String?) {
        self.reference = reference
        self.suggestedName = suggestedName
    }
}

public struct ResolvedStream: Sendable {
    public enum Format: Sendable {
        /// An HLS playlist, relayed or converted as needed.
        case hls
        /// A continuous MPEG transport stream (e.g. a TV tuner), always converted by FFmpeg.
        case transportStream
    }

    public var playlistURL: URL
    public var format: Format
    /// Applied to every upstream request made for this stream: playlists, keys, and segments.
    public var prepare: @Sendable (inout URLRequest) -> Void

    public init(playlistURL: URL, format: Format = .hls, prepare: @escaping @Sendable (inout URLRequest) -> Void = { _ in }) {
        self.playlistURL = playlistURL
        self.format = format
        self.prepare = prepare
    }
}

public enum ProviderError: LocalizedError, Equatable {
    case unrecognizedInput
    case unknownProvider(ProviderID)
    case notAPlaylist
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unrecognizedInput: "Enter an HLS stream URL (.m3u8) or a broadcast stream URL (such as an HDHomeRun channel)."
        case .unknownProvider(let id): "This channel uses “\(id)”, which this version of TV Thing doesn't support."
        case .notAPlaylist: "That URL didn't return an HLS playlist or a broadcast stream."
        case .unavailable(let reason): reason
        }
    }
}

public extension ProviderID {
    static let hls: ProviderID = "hls"
    static let transportStream: ProviderID = "mpegts"
}

/// The set of providers available to the app, in routing priority order.
public struct ProviderRegistry: Sendable {
    public let providers: [any StreamProvider]

    public init(providers: [any StreamProvider]) {
        self.providers = providers
    }

    /// Specific providers first, then the generic URL providers: an HLS playlist, or
    /// failing that, a raw broadcast stream.
    public static func standard(http: HTTPClient = .shared) -> ProviderRegistry {
        ProviderRegistry(providers: [HLSProvider(http: http), TransportStreamProvider(http: http)])
    }

    public func provider(for id: ProviderID) throws -> any StreamProvider {
        guard let provider = providers.first(where: { $0.id == id }) else { throw ProviderError.unknownProvider(id) }
        return provider
    }

    /// Asks each provider that accepts the input in turn; the first that recognizes it wins.
    public func candidate(for input: String) async throws -> SourceCandidate {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var firstError: Error?
        for provider in providers where provider.accepts(trimmed) {
            do {
                return try await provider.candidate(for: trimmed)
            } catch {
                firstError = firstError ?? error
            }
        }
        throw firstError ?? ProviderError.unrecognizedInput
    }

    public func resolve(_ reference: SourceReference, refresh: Bool = false) async throws -> ResolvedStream {
        try await provider(for: reference.provider).resolve(reference, refresh: refresh)
    }

    public func summary(of reference: SourceReference) -> String {
        (try? provider(for: reference.provider).summary(of: reference)) ?? "\(reference.provider): \(reference.value)"
    }
}
