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
    public var playlistURL: URL
    /// Applied to every upstream request made for this stream: playlists, keys, and segments.
    public var prepare: @Sendable (inout URLRequest) -> Void

    public init(playlistURL: URL, prepare: @escaping @Sendable (inout URLRequest) -> Void = { _ in }) {
        self.playlistURL = playlistURL
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
        case .unrecognizedInput: "Enter an HLS stream URL (.m3u8) or a supported channel link."
        case .unknownProvider(let id): "This channel uses “\(id)”, which this version of TV Thing doesn't support."
        case .notAPlaylist: "That URL didn't return an HLS playlist."
        case .unavailable(let reason): reason
        }
    }
}

public extension ProviderID {
    static let hls: ProviderID = "hls"
}

/// The set of providers available to the app, in routing priority order.
public struct ProviderRegistry: Sendable {
    public let providers: [any StreamProvider]

    public init(providers: [any StreamProvider]) {
        self.providers = providers
    }

    /// Specific providers first; the generic HLS provider catches any remaining URL,
    /// so it must stay last.
    public static func standard(http: HTTPClient = .shared) -> ProviderRegistry {
        ProviderRegistry(providers: [HLSProvider(http: http)])
    }

    public func provider(for id: ProviderID) throws -> any StreamProvider {
        guard let provider = providers.first(where: { $0.id == id }) else { throw ProviderError.unknownProvider(id) }
        return provider
    }

    public func candidate(for input: String) async throws -> SourceCandidate {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let provider = providers.first(where: { $0.accepts(trimmed) }) else { throw ProviderError.unrecognizedInput }
        return try await provider.candidate(for: trimmed)
    }

    public func resolve(_ reference: SourceReference, refresh: Bool = false) async throws -> ResolvedStream {
        try await provider(for: reference.provider).resolve(reference, refresh: refresh)
    }

    public func summary(of reference: SourceReference) -> String {
        (try? provider(for: reference.provider).summary(of: reference)) ?? "\(reference.provider): \(reference.value)"
    }
}
