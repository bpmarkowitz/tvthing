import Foundation

/// Identifies a stream provider, such as `hls`.
///
/// Stored as a plain string so channel libraries and packs that reference a provider
/// this build doesn't know about still round-trip without data loss.
public struct ProviderID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// A provider-specific pointer to a stream. `value` is opaque to everything except the provider.
public struct SourceReference: Codable, Hashable, Sendable {
    public var provider: ProviderID
    public var value: String

    public init(provider: ProviderID, value: String) {
        self.provider = provider
        self.value = value
    }
}

/// How a channel is delivered to the Car Thing.
public enum PlaybackMode: String, Codable, CaseIterable, Sendable {
    /// Relay the stream untouched when the probe says the Car Thing can play it, otherwise convert.
    case automatic
    /// Always relay the stream untouched.
    case direct
    /// Always convert the stream with FFmpeg.
    case convert
}

public struct Channel: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var source: SourceReference
    public var playback: PlaybackMode

    public init(id: UUID = UUID(), name: String, source: SourceReference, playback: PlaybackMode = .automatic) {
        self.id = id
        self.name = name
        self.source = source
        self.playback = playback
    }

    private enum CodingKeys: String, CodingKey { case id, name, source, playback }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        source = try container.decode(SourceReference.self, forKey: .source)
        playback = try container.decodeIfPresent(PlaybackMode.self, forKey: .playback) ?? .automatic
    }
}
