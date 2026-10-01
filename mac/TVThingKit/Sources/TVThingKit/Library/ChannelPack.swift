import Foundation

/// A shareable list of channels. See `docs/channel-packs.md` for the file format.
public struct ChannelPack: Codable, Equatable, Sendable {
    public static let format = "tvthing.channels"
    public static let currentVersion = 1
    public static let fileExtension = "tvthing"

    public struct Entry: Codable, Equatable, Sendable {
        public var name: String
        public var source: SourceReference
        public var playback: PlaybackMode?

        public init(name: String, source: SourceReference, playback: PlaybackMode? = nil) {
            self.name = name
            self.source = source
            self.playback = playback
        }

        private enum CodingKeys: String, CodingKey { case name, source, url, playback }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            playback = try container.decodeIfPresent(PlaybackMode.self, forKey: .playback)
            if let source = try container.decodeIfPresent(SourceReference.self, forKey: .source) {
                self.source = source
            } else if let url = try container.decodeIfPresent(String.self, forKey: .url) {
                // Shorthand for hand-written packs: a bare URL is a direct HLS stream.
                source = SourceReference(provider: .hls, value: url)
            } else {
                throw DecodingError.dataCorruptedError(forKey: .source, in: container, debugDescription: "A channel needs a `source` or `url`.")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(source, forKey: .source)
            try container.encodeIfPresent(playback, forKey: .playback)
        }
    }

    public var format: String
    public var version: Int
    public var name: String?
    public var channels: [Entry]

    public init(name: String? = nil, channels: [Entry]) {
        self.format = Self.format
        self.version = Self.currentVersion
        self.name = name
        self.channels = channels
    }

    public init(name: String? = nil, exporting channels: [Channel]) {
        self.init(name: name, channels: channels.map {
            Entry(name: $0.name, source: $0.source, playback: $0.playback == .automatic ? nil : $0.playback)
        })
    }

    /// Fresh channels (with new identities) ready to add to a library.
    public func makeChannels() -> [Channel] {
        channels.map { Channel(name: $0.name, source: $0.source, playback: $0.playback ?? .automatic) }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Decodes a TV Thing channel pack or, failing that, an M3U playlist.
    public static func decode(_ data: Data) throws -> ChannelPack {
        if let text = String(data: data, encoding: .utf8), text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") {
            return try M3UPlaylistParser.pack(from: text)
        }
        let pack: ChannelPack
        do {
            pack = try JSONDecoder().decode(ChannelPack.self, from: data)
        } catch {
            throw ChannelPackError.unreadable
        }
        guard pack.format == format else { throw ChannelPackError.unreadable }
        guard pack.version <= currentVersion else { throw ChannelPackError.unsupportedVersion(pack.version) }
        return pack
    }
}

public enum ChannelPackError: LocalizedError, Equatable {
    case unreadable
    case unsupportedVersion(Int)
    case empty

    public var errorDescription: String? {
        switch self {
        case .unreadable: "This file isn't a TV Thing channel pack or M3U playlist."
        case .unsupportedVersion(let version): "This channel pack uses format version \(version), which needs a newer TV Thing."
        case .empty: "No channels were found in this file."
        }
    }
}

/// Reads extended M3U playlists (the IPTV convention) into channel pack entries.
public enum M3UPlaylistParser {
    public static func pack(from text: String) throws -> ChannelPack {
        var entries: [ChannelPack.Entry] = []
        var pendingName: String?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF") {
                pendingName = name(fromInfo: line)
            } else if !line.isEmpty, !line.hasPrefix("#") {
                guard let url = URL(string: line), ["http", "https"].contains(url.scheme?.lowercased()) else {
                    pendingName = nil
                    continue
                }
                let fallback = url.deletingPathExtension().lastPathComponent
                let name = pendingName.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
                entries.append(.init(name: name, source: .init(provider: .hls, value: url.absoluteString)))
                pendingName = nil
            }
        }
        guard !entries.isEmpty else { throw ChannelPackError.empty }
        return ChannelPack(channels: entries)
    }

    /// `#EXTINF:-1 tvg-name="Foo" group-title="Bar",Display Name` → `Display Name` (or `tvg-name`).
    static func name(fromInfo line: String) -> String {
        if let comma = lastUnquotedComma(in: line) {
            let title = line[line.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return title }
        }
        if let range = line.range(of: #"tvg-name="([^"]*)""#, options: .regularExpression) {
            return String(line[range].dropFirst(10).dropLast())
        }
        return ""
    }

    private static func lastUnquotedComma(in line: String) -> String.Index? {
        var quoted = false
        var result: String.Index?
        for index in line.indices {
            switch line[index] {
            case "\"": quoted.toggle()
            case "," where !quoted: result = index
            default: break
            }
        }
        return result
    }
}
